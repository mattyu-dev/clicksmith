import AVFoundation
import Foundation

struct MediaColor: Sendable {
    let properties: [String: String]
    let keepHDR: Bool
    let hdrMetadata: [String: Data]

    init(source: NSDictionary?, codec: AVVideoCodecType) {
        let transfer = source?[kCMFormatDescriptionExtension_TransferFunction] as? String
        let hdr = transfer == AVVideoTransferFunction_ITU_R_2100_HLG || transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ
        keepHDR = hdr && codec != .h264
        let toneMap = hdr && !keepHDR
        properties = [
            AVVideoColorPrimariesKey: toneMap ? AVVideoColorPrimaries_ITU_R_709_2
                : (source?[kCMFormatDescriptionExtension_ColorPrimaries] as? String ?? AVVideoColorPrimaries_ITU_R_709_2),
            AVVideoTransferFunctionKey: toneMap ? AVVideoTransferFunction_ITU_R_709_2
                : (transfer ?? AVVideoTransferFunction_ITU_R_709_2),
            AVVideoYCbCrMatrixKey: toneMap ? AVVideoYCbCrMatrix_ITU_R_709_2
                : (source?[kCMFormatDescriptionExtension_YCbCrMatrix] as? String ?? AVVideoYCbCrMatrix_ITU_R_709_2)
        ]
        var metadata: [String: Data] = [:]
        if keepHDR {
            for key in [kCMFormatDescriptionExtension_MasteringDisplayColorVolume, kCMFormatDescriptionExtension_ContentLightLevelInfo] {
                if let data = source?[key] as? Data { metadata[key as String] = data }
            }
        }
        hdrMetadata = metadata
    }

    func apply(to pixel: CVPixelBuffer) {
        for (setting, attachment) in [(AVVideoColorPrimariesKey, kCVImageBufferColorPrimariesKey),
            (AVVideoTransferFunctionKey, kCVImageBufferTransferFunctionKey), (AVVideoYCbCrMatrixKey, kCVImageBufferYCbCrMatrixKey)] {
            if let value = properties[setting] { CVBufferSetAttachment(pixel, attachment, value as CFString, .shouldPropagate) }
        }
        for key in [kCVImageBufferMasteringDisplayColorVolumeKey, kCVImageBufferContentLightLevelInfoKey] {
            if let data = hdrMetadata[key as String] { CVBufferSetAttachment(pixel, key, data as CFData, .shouldPropagate) }
            else { CVBufferRemoveAttachment(pixel, key) }
        }
    }
}
