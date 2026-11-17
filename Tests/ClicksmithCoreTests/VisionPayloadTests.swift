import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct VisionPayloadTests {
    @Test func parsesEveryPayloadKind() throws {
        let url = try #require(URL(string: "https://apple.com"))
        #expect(CodeReader.parse(url.absoluteString) == .url(url))
        #expect(CodeReader.parse("WIFI:S:Guest;T:nopass;H:true;;") ==
                .wifi(ssid: "Guest", password: nil, security: "nopass", hidden: true))
        let vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Jane\\, Doe\r\nEND:VCARD"
        #expect(CodeReader.parse(vcard) == .contact(vcard: vcard, name: "Jane, Doe"))
        let event = "BEGIN:VEVENT\nSUMMARY:Team\\; lunch\nDTSTART:20261116T120000Z\nEND:VEVENT"
        #expect(CodeReader.parse(event) == .event(ics: event, title: "Team; lunch", start: Date(timeIntervalSince1970: 1_794_830_400)))
        #expect(CodeReader.parse("mailto:jane@example.com?subject=Hello%20there&body=A%2BB") ==
                .email(to: "jane@example.com", subject: "Hello there", body: "A+B"))
        #expect(CodeReader.parse("tel:+33123456789") == .phone("+33123456789"))
        #expect(CodeReader.parse("SMSTO:+33123456789:Hello: again") == .sms(number: "+33123456789", body: "Hello: again"))
        #expect(CodeReader.parse("sms:+33123456789?body=Hello%20there") == .sms(number: "+33123456789", body: "Hello there"))
        #expect(CodeReader.parse("geo:48.8566,2.3522?z=12") == .geo(lat: 48.8566, lon: 2.3522))
        #expect(CodeReader.parse(" Bonjour 🌍\n") == .text(" Bonjour 🌍\n"))
    }

    @Test func wifiEscapesRoundTripWithoutSplittingFields() {
        let encoded = CodeWriter.wifiString(ssid: "a\\b;c,d:e\"f", password: "p;\\,:\"", security: "WPA", hidden: true)
        #expect(encoded == #"WIFI:T:WPA;S:a\\b\;c\,d\:e\"f;P:p\;\\\,\:\";H:true;;"#)
        #expect(CodeReader.parse(encoded) == .wifi(ssid: "a\\b;c,d:e\"f", password: "p;\\,:\"", security: "WPA", hidden: true))
        #expect(CodeReader.parse(#"WIFI:S:ends\\;P:;;"#) == .wifi(ssid: "ends\\", password: "", security: "nopass", hidden: false))
    }

    @Test func foldedNamesAndEventTimeZones() {
        let vcard = "BEGIN:VCARD\nFN:Jane \n Doe\nEND:VCARD"
        #expect(CodeReader.parse(vcard) == .contact(vcard: vcard, name: "Jane Doe"))
        let event = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Planning\nDTSTART;TZID=Europe/Paris:20261116T130000\nEND:VEVENT\nEND:VCALENDAR"
        #expect(CodeReader.parse(event) == .event(ics: event, title: "Planning", start: Date(timeIntervalSince1970: 1_794_830_400)))
    }

    @Test func floatingAndDateOnlyEventsUseLocalTime() throws {
        let floating = "BEGIN:VEVENT\nDTSTART:20261116T130000\nEND:VEVENT"
        let allDay = "BEGIN:VEVENT\nDTSTART;VALUE=DATE:20261116\nEND:VEVENT"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let localTime = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 13)))
        let localMidnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        #expect(CodeReader.parse(floating) == .event(ics: floating, title: nil, start: localTime))
        #expect(CodeReader.parse(allDay) == .event(ics: allDay, title: nil, start: localMidnight))
    }

    @Test(arguments: ["WIFI:T:WPA;;", "geo:91,2", "geo:nan,2", "geo:1,181", "mailto:", "tel:", "sms:", "https://", "BEGIN:VCARD\nFN:Incomplete"])
    func malformedPayloadStaysText(_ value: String) {
        #expect(CodeReader.parse(value) == .text(value))
    }

    @Test func assessesRequiredAndAdditionalPhishingSignals() throws {
        let cases: [(String, LinkRisk.Level)] = [
            ("https://apple.com", .safe),
            ("https://аpple.com", .danger),
            ("https://xn--pple-43d.com", .danger),
            ("https://bit.ly/x", .caution),
            ("http://192.168.0.1@evil.com", .danger),
            ("https://paypal.com.evil.io", .danger),
            ("https://accounts.google.com", .safe),
            ("https://paypal.com.login.paypal.com", .safe),
            ("https://notapple.com", .safe),
            ("https://192.168.0.1", .caution),
            ("https://[::1]/", .caution),
            ("http://example.org", .caution),
            ("javascript:alert(1)", .danger),
            ("data:text/html,test", .danger),
            ("https://example.org?q=" + String(repeating: "x", count: 2_100), .caution)
        ]
        for (value, level) in cases {
            let risk = CodeReader.assess(try #require(URL(string: value)))
            #expect(risk.level == level, "\(value): \(risk.reasons)")
            #expect(risk.reasons.isEmpty == (level == .safe))
        }
        let combined = CodeReader.assess(try #require(URL(string: "http://192.168.0.1@bit.ly/x")))
        #expect(combined.level == .danger)
        #expect(combined.reasons.count >= 3)
    }

    @Test func countryDomainsAndSingleScriptHomographs() throws {
        let cases: [(String, LinkRisk.Level)] = [
            ("https://www.amazon.com.au", .safe), ("https://www.apple.com.cn", .safe),
            ("https://google.com.br", .safe), ("https://www.apple.com.co.uk", .safe),
            ("https://apple.com.com.br", .safe), ("https://apple.com.au.evil.io", .danger),
            ("https://secure-paypal.com.evil.io", .danger), ("https://secure-paypal.com", .safe),
            ("https://аррӏе.com", .danger), ("https://xn--80ak6aa92e.com", .danger),
            ("https://αρρλε.net", .danger), ("https://münchen.de", .caution),
            ("https://пример.com", .caution)
        ]
        for (s, want) in cases {
            let risk = CodeReader.assess(try #require(URL(string: s)))
            #expect(risk.level == want, "\(s): \(risk.reasons)")
        }
        for s in ["http://3232235521/", "https://3232235521/", "https://0xc0a80001/"] {
            let risk = CodeReader.assess(try #require(URL(string: s)))
            #expect(risk.level == .caution)
            #expect(risk.reasons.contains { $0.contains("IP address") })
        }
    }

    @Test func mecardAndMatmsgUseEscapedFields() {
        let mecard = #"MECARD:N:Doe,Jane;TEL:+33123456789;TEL:+33987654321;EMAIL:jane@example.com;NOTE:Meet\; tomorrow;;"#
        let card = "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Doe;Jane;;;\r\nFN:Jane Doe\r\nTEL:+33123456789\r\nTEL:+33987654321\r\nEMAIL:jane@example.com\r\nNOTE:Meet\\; tomorrow\r\nEND:VCARD\r\n"
        #expect(CodeReader.parse(mecard) == .contact(vcard: card, name: "Jane Doe"))
        #expect(CodeReader.parse(#"MATMSG:TO:jane@example.com;SUB:Hello\; Jane;BODY:Meet at 12\:30\; bring A\\B;;"#) ==
                .email(to: "jane@example.com", subject: "Hello; Jane", body: "Meet at 12:30; bring A\\B"))
        #expect(CodeReader.parse("MECARD:TEL:123;;") == .text("MECARD:TEL:123;;"))
        #expect(CodeReader.parse("MATMSG:SUB:No recipient;;") == .text("MATMSG:SUB:No recipient;;"))
    }

    @Test func wifiQuotesOnlyDelimitUnescapedValues() {
        #expect(CodeReader.parse(#"WIFI:S:"ABCDEF";P:"12345678";T:WPA;;"#) ==
                .wifi(ssid: "ABCDEF", password: "12345678", security: "WPA", hidden: false))
        #expect(CodeReader.parse(#"WIFI:S:\"ABCDEF\";P:\"12345678\";T:WPA;;"#) ==
                .wifi(ssid: "\"ABCDEF\"", password: "\"12345678\"", security: "WPA", hidden: false))
        #expect(CodeWriter.wifiString(ssid: "ABCDEF", password: "12345678") == #"WIFI:T:WPA;S:"ABCDEF";P:"12345678";H:false;;"#)
        #expect(CodeReader.parse(CodeWriter.wifiString(ssid: "ABCDEF", password: "12345678")) ==
                .wifi(ssid: "ABCDEF", password: "12345678", security: "WPA", hidden: false))
    }
}
