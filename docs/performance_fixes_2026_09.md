# Streaming e controle: correções de setembro de 2026

## Caminho de vídeo

O callback nativo copia cada access unit para memória própria e retorna imediatamente. O decoder usa uma fila serial e admite no máximo doze submissões CPU pendentes. A vaga é devolvida após a submissão ao VideoToolbox, sem depender da chegada do output assíncrono. `false` significa exclusivamente que o frame não entrou na fila; não é utilizado como pedido genérico de keyframe depois de aceitar um frame.

Perda de frames e `recovered` não invalidam a sessão: no Chiaki, `recovered` indica remapeamento para uma referência anterior, que precisa continuar presente no decoder. Não há descarte silencioso de frames aceitos enquanto se aguarda IDR. Somente mudança de parâmetros ou erro de sessão inválida recria o VideoToolbox. Erros de dados são contabilizados; a recuperação de referências segue o protocolo Chiaki. Todas as slices VCL de um frame formam uma única amostra, com timestamp monotônico local.

Frames decodificados substituem um único slot. Não há publicação de texturas por frame em SwiftUI nem fila intermediária no MainActor. O MTKView agenda o trabalho em uma fila serial separada; inclusive a aquisição do drawable ocorre nessa fila. Há no máximo dois command buffers em trânsito. O temporizador do MTKView solicita a cadência máxima até 120 Hz e só envia trabalho à GPU quando há um frame novo. O antigo FramePacer não é iniciado.

Upscale e renderização compartilham o mesmo command buffer e a mesma command queue. Assim, a textura reutilizável de saída é escrita e lida em ordem, sem `waitUntilCompleted()` na reprodução e sem depender de sincronização entre filas diferentes. Os CVPixelBuffers e CVMetalTextures permanecem retidos até a conclusão da GPU.

1080p nativo é o padrão. O seletor na janela oferece MetalFX e Enhanced. Sob pressão térmica séria/crítica, o renderer usa resolução nativa. Os upscalers são inicializados apenas quando utilizados. O caminho atual recebe BGRA SDR; não habilita HDR/P010. O shader de sharpening limita as coordenadas nas bordas para evitar leituras fora da textura.

## Controle e biblioteca nativa

Callbacks do GameController usam uma fila dedicada e encaminham mudanças imediatamente, complementando o polling a 120 Hz. Amostragem e encaminhamento são serializados para impedir que uma amostra antiga ultrapasse um evento novo. Na desconexão do controle, um estado neutro é encaminhado.

O feedback sender foi recompilado e incorporado em `libchiaki_full.a`. Copia estados sob um lock curto e envia os pacotes fora desse lock. Uma FIFO limitada preserva transições de botões/gatilhos/toques; movimentos analógicos consecutivos sem essas transições são combinados. Em sobrecarga extrema, a FIFO de 256 entradas descarta a mais antiga e registra o ocorrido, preservando o estado mais recente. Essa fila auxiliar pressupõe uma única sessão ativa, como o wrapper do aplicativo, e mantém o layout binário de ChiakiFeedbackSender intacto.

`chiaki_socket_set_nonblock()` agora usa `fcntl`, preserva flags e retorna erros reais. Não altera indiscriminadamente os sockets UDP nem o protocolo de retransmissão. A finalização nativa ocorre fora da interface; os buffers de áudio só são reiniciados depois do término dos callbacks nativos. O áudio usa um único nó estéreo e uma FIFO intercalada para manter L/R sincronizados. A capacidade máxima é 200 ms; acima de 100 ms, o consumidor descarta amostras antigas até a região de 40 ms. O consumidor usa try-lock, emite silêncio em caso de contenção e não aloca memória no callback. Não utiliza mais a correção lenta de 0,1% para eliminar segundos de atraso.

Criação do engine, padrões, players e atualizações de vibração são executadas em uma fila própria. Atualizações são combinadas; uma falha do serviço desabilita haptics até reconexão ou retorno ao foreground, sem tentativas por pacote. Nenhuma chamada XPC de haptics ocorre no MainActor.

## Reproduzir e testar

- `bash scripts/rebuild_feedback_module.sh`: aplica o patch ao fonte do commit fixado e substitui somente `feedbacksender.c.o` na biblioteca. Não modifica a árvore local do chiaki-ng.
- `bash scripts/test_feedback_sender.sh`: simula um envio bloqueado, verifica atualização independente, combinação de movimento e preservação de pressionar/soltar.
- `bash scripts/test_socket_mode.sh`: verifica flags e falhas de descritor da implementação usada no aplicativo.
- `bash scripts/test_video_decoder.sh`: gera frames reais H.264/HEVC no VideoToolbox e verifica frames dependentes, preservação das referências após avisos de perda, saturação/rejeição/retomada da fila, parser Annex-B e rejeição após stop.
- `bash scripts/test_audio_buffer.sh`: simula sete segundos sem consumo, verifica limite de atraso, canais alinhados, concorrência e wraparound.
- `bash scripts/test_video_gpu.sh`: executa os upscalers na GPU do Mac, reutiliza as texturas em command buffers consecutivos e verifica pixels no centro e nas bordas.

Os testes de VideoToolbox e Metal precisam de acesso aos serviços de mídia/GPU do macOS. Os arquivos HostTests são harnesses executados pelos scripts, não devem ser adicionados ao target XCTest do visionOS.

## Validação no Vision Pro

Os testes de host e a compilação não medem desempenho de uma sessão PS5 real. Comparar 1080p nativo, MetalFX e Enhanced na mesma rede, com o mesmo jogo, por pelo menos alguns minutos. Testar também perda temporária de rede, fechar/reabrir a janela e desconectar/reconectar o controle enquanto um botão está pressionado.

Logs `[Video] receive-to-GPU`, `GPU` e `receive-to-present` medem apenas o percurso local a partir da chegada do frame. Não incluem captura/codificação no PS5, transporte anterior à recepção ou latência Bluetooth. Logs `[Input]` registram chamadas nativas acima de 8,33 ms ou erros. Para medir botão-até-imagem, ainda é necessária uma medição externa ou instrumentação coordenada no console.

## Resultado desta validação

Em 2026-09-05, a compilação final Release para `generic/platform=visionOS`, sem assinatura, terminou com `BUILD SUCCEEDED`. Os quatro scripts de teste acima passaram. A GPU do Mac validou os caminhos MetalFX e Enhanced, inclusive reutilização da textura entre frames e pixels das bordas. O VideoToolbox validou ambos os codecs. Nenhuma sessão com PS5/Vision Pro foi executada nesta validação; ganhos de latência no dispositivo ainda não foram medidos.


## Regressão observada e correção

O arquivo `logs` mostrou 16 rejeições de frames, 186 avisos de referências ausentes, 161 overflows do buffer de envio Takion e áudio acumulado de até 4.986,5 ms. A implementação inicial misturava aceitação de frames com pedidos de recuperação, apagava referências recuperáveis e vinculava a capacidade da fila à chegada dos outputs do VideoToolbox. Isso foi corrigido conforme descrito acima. Os testes anteriores com keyframes isolados não cobriam essas condições; o harness agora exige frames P e provoca saturação da fila antes de verificar a retomada.

O timestamp de apresentação zero/negativo é rejeitado. Diagnósticos do decoder e renderer são emitidos por intervalo de tempo; não dependem mais de apresentar exatamente cada frame múltiplo de 300. Eles permitem distinguir recepção, output do decoder e disponibilidade de drawable no próximo teste no Vision Pro.
