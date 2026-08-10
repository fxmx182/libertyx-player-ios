import Foundation

/// Garante que o LabPlayer apareça no app Arquivos.
///
/// Pegadinha do iOS: mesmo com `UIFileSharingEnabled`, a pasta do app **não
/// aparece** em "No meu iPhone" enquanto estiver vazia. Isso cria um impasse
/// circular — não dá para copiar vídeos para lá porque o destino não existe na
/// tela, e ele não existe na tela porque está vazio.
///
/// Criar um item na primeira execução resolve.
enum DocumentsSetup {

    static func run() {
        let gerenciador = FileManager.default
        guard let documentos = gerenciador.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let conteudo = (try? gerenciador.contentsOfDirectory(atPath: documentos.path)) ?? []
        guard conteudo.isEmpty else { return }

        // Uma pasta óbvia para arrastar arquivos, e um aviso explicando o
        // porquê de ela existir — para não parecer lixo deixado pelo app.
        let videos = documentos.appendingPathComponent("Vídeos", isDirectory: true)
        try? gerenciador.createDirectory(at: videos, withIntermediateDirectories: true)

        let aviso = """
        LabPlayer
        =========

        Copie seus vídeos para a pasta "Vídeos" e eles aparecem no app
        automaticamente, agrupados por pasta.

        Como copiar:
          · Arraste arquivos aqui pelo app Arquivos
          · Receba por AirDrop e escolha LabPlayer
          · Em outro app, use Compartilhar > Salvar em Arquivos

        Também dá para reproduzir sem copiar nada:
          · Pendrive na USB-C: no app, + > Adicionar pasta
          · Servidor de rede: no app, ícone de servidor > Servidores SMB

        Este arquivo existe por um motivo técnico: o iOS esconde a pasta de um
        app enquanto ela está vazia. Pode apagá-lo depois de colocar algum
        vídeo aqui.
        """
        let leiaMe = documentos.appendingPathComponent("LEIA-ME.txt")
        try? aviso.write(to: leiaMe, atomically: true, encoding: .utf8)
    }
}
