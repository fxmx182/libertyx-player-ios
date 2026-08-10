import UIKit
import AVFoundation
import CoreVideo

/// Superfície onde os quadros decodificados aparecem.
///
/// `AVSampleBufferDisplayLayer` em vez de Metal próprio: ela aceita
/// `CVPixelBuffer` direto da saída do VideoToolbox, sem cópia nem conversão de
/// cor na CPU — que num vídeo 4K seria o gargalo do player inteiro.
final class VideoRenderView: UIView, VideoGravityAdjustable {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    /// Exposta porque o Picture in Picture do iOS é construído sobre ela —
    /// é o que permite a janela flutuante sem um segundo player.
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    private var formatDescription: CMVideoFormatDescription?
    private var lastPixelBufferSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    func setGravity(_ gravity: AVLayerVideoGravity) {
        displayLayer.videoGravity = gravity
    }

    /// Exibe um quadro imediatamente.
    ///
    /// O ritmo é decidido pelo motor, que compara o tempo do quadro com o
    /// relógio do áudio — por isso `DisplayImmediately`. Deixar a layer
    /// agendar sozinha exigiria um timebase sincronizado com o áudio, o que
    /// tira do motor justamente o controle que a rolagem frame a frame precisa.
    func display(_ pixelBuffer: CVPixelBuffer) {
        let tamanho = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                             height: CVPixelBufferGetHeight(pixelBuffer))

        // A descrição de formato precisa ser refeita quando a resolução muda
        // (acontece em streams adaptativos e ao trocar de faixa).
        if formatDescription == nil || tamanho != lastPixelBufferSize {
            var nova: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &nova)
            guard status == noErr, let nova else { return }
            formatDescription = nova
            lastPixelBufferSize = tamanho
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dicionario = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                           to: CFMutableDictionary.self)
            CFDictionarySetValue(dicionario,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    /// Limpa o que está na fila — usado ao buscar, para o quadro antigo não
    /// piscar antes do novo.
    func flush() {
        displayLayer.flushAndRemoveImage()
        formatDescription = nil
        lastPixelBufferSize = .zero
    }
}
