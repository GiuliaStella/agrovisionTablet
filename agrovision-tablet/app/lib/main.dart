
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kVerdeEscuro = Color(0xFF0B4A2A);
const kVerde = Color(0xFF4C9A2A);
const kFundo = Color(0xFFF3F6F2);
// Bluetooth PAN: o tablet costuma ser 192.168.44.1 e o PC recebe 192.168.44.x.
// Confira o IP do PC no terminal do servidor e ajuste pela engrenagem.
const kUrlPadrao = 'http://192.168.44.2:8000';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const AgroVisionApp());
}

class AgroVisionApp extends StatelessWidget {
  const AgroVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AGROVISION',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kFundo,
        colorScheme: ColorScheme.fromSeed(seedColor: kVerde),
        fontFamily: 'Roboto',
      ),
      home: const HomePage(),
    );
  }
}

Stream<Uint8List> mjpegFrames(String url) async* {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();

    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }

    var buffer = Uint8List(0);

    await for (final chunk in response) {
      final junto = Uint8List(buffer.length + chunk.length)
        ..setRange(0, buffer.length, buffer)
        ..setRange(buffer.length, buffer.length + chunk.length, chunk);

      buffer = junto;

      while (true) {
        final inicio = _acharMarcador(buffer, 0xD8, 0);
        if (inicio < 0) {
          if (buffer.length > 1) {
            buffer = buffer.sublist(buffer.length - 1);
          }
          break;
        }

        final fim = _acharMarcador(buffer, 0xD9, inicio + 2);
        if (fim < 0) {
          if (inicio > 0) buffer = buffer.sublist(inicio);
          break;
        }

        yield buffer.sublist(inicio, fim + 2);
        buffer = buffer.sublist(fim + 2);
      }
    }
  } finally {
    client.close(force: true);
  }
}

int _acharMarcador(Uint8List bytes, int segundo, int desde) {
  for (var i = desde; i < bytes.length - 1; i++) {
    if (bytes[i] == 0xFF && bytes[i + 1] == segundo) return i;
  }
  return -1;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _carregarUrl();
  }

  Future<void> _carregarUrl() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _url = prefs.getString('url') ?? kUrlPadrao;
    });
  }

  Future<void> _editarUrl() async {
    final controller = TextEditingController(text: _url);

    final novo = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Endereço do servidor'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'URL do servidor',
                  hintText: 'http://127.0.0.1:8000',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'USB: http://127.0.0.1:8000\n'
                'Wi-Fi: http://IP-DO-PC:8000',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );

    if (novo == null || novo.isEmpty) return;

    var url = novo;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('url', url);

    if (!mounted) return;
    setState(() => _url = url);
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;

    return Scaffold(
      body: SafeArea(
        child: url == null
            ? const Center(child: CircularProgressIndicator())
            : LiveView(
                key: ValueKey(url),
                baseUrl: url,
                onConfigurar: _editarUrl,
              ),
      ),
    );
  }
}

class LiveView extends StatefulWidget {
  const LiveView({
    super.key,
    required this.baseUrl,
    required this.onConfigurar,
  });

  final String baseUrl;
  final VoidCallback onConfigurar;

  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> {
  Uint8List? _frame;
  Timer? _timerStatus;

  bool _servidorOnline = false;
  bool _reconhecimentoAtivo = false;
  bool _ocupado = false;

  // Estado visual do botão. Só muda após uma resposta HTTP de sucesso.
  bool _laserAtivo = false;
  bool _laserOcupado = false;

  String _status = 'Verificando servidor...';
  String? _erro;
  int _ervas = 0;
  int _plantas = 0;
  double _fps = 0;

  @override
  void initState() {
    super.initState();
    _buscarStatus();
    _timerStatus = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _buscarStatus(),
    );
    _loopVideo();
  }

  @override
  void dispose() {
    _timerStatus?.cancel();
    super.dispose();
  }

  Future<void> _loopVideo() async {
    while (mounted) {
      try {
        await for (final jpg in mjpegFrames('${widget.baseUrl}/video')) {
          if (!mounted) return;
          setState(() => _frame = jpg);
        }
      } catch (_) {
        // O status do servidor será atualizado pela consulta periódica.
      }

      if (!mounted) return;
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _buscarStatus() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);

    try {
      final req = await client.getUrl(
        Uri.parse('${widget.baseUrl}/status'),
      );
      final res = await req.close().timeout(
        const Duration(seconds: 3),
      );

      if (res.statusCode != 200) {
        throw HttpException('Servidor respondeu ${res.statusCode}');
      }

      final corpo = await res.transform(utf8.decoder).join();
      final dados = jsonDecode(corpo) as Map<String, dynamic>;

      if (!mounted) return;

      final status = (dados['status'] ?? 'Desconhecido').toString();
      final ativo = status == 'Conectado' ||
          status == 'Carregando modelo' ||
          status == 'Iniciando' ||
          status == 'Iniciando ou conectado';

      setState(() {
        _servidorOnline = true;
        _status = status;
        _reconhecimentoAtivo = ativo;
        _ervas = (dados['erva_daninha'] as num?)?.toInt() ??
            (dados['ervas'] as num?)?.toInt() ??
            0;
        _plantas = (dados['planta'] as num?)?.toInt() ??
            (dados['plantas'] as num?)?.toInt() ??
            0;
        _fps = (dados['fps'] as num?)?.toDouble() ?? 0;

        if (status == 'Erro' || status == 'Erro na camera') {
          _erro = status == 'Erro na camera'
              ? 'Não foi possível abrir a câmera do computador.'
              : 'Ocorreu um erro no reconhecimento. Confira o terminal.';
        } else {
          _erro = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _servidorOnline = false;
        _reconhecimentoAtivo = false;
        _status = 'Sem conexão';
        _erro = 'Confira se o servidor Python está rodando.';
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _enviarComando(String comando) async {
    if (_ocupado) return;

    setState(() {
      _ocupado = true;
      _erro = null;
    });

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);

    try {
      final request = await client.postUrl(
        Uri.parse('${widget.baseUrl}/$comando'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final corpo = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Erro ${response.statusCode}: $corpo');
      }

      await _buscarStatus();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            comando == 'start'
                ? 'Comando para iniciar enviado!'
                : 'Comando para parar enviado!',
          ),
          backgroundColor: kVerdeEscuro,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _erro = 'Não foi possível enviar o comando: $e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _ocupado = false);
    }
  }

  // Requer que o servidor Python implemente POST /laser/on e POST /laser/off.
  Future<void> _alternarLaser() async {
    if (_laserOcupado || !_servidorOnline) return;

    final ligar = !_laserAtivo;

    setState(() {
      _laserOcupado = true;
      _erro = null;
    });

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);

    try {
      final request = await client.postUrl(
        Uri.parse('${widget.baseUrl}/laser/${ligar ? 'on' : 'off'}'),
      );

      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final corpo = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Erro ${response.statusCode}: $corpo');
      }

      if (!mounted) return;

      setState(() => _laserAtivo = ligar);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ligar
                ? 'Comando para ligar o laser aceito pelo servidor.'
                : 'Comando para desligar o laser aceito pelo servidor.',
          ),
          backgroundColor: ligar ? kVerdeEscuro : Colors.black87,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = 'Comando do laser não disponível: $e';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Laser não conectado. Verifique o servidor e o hardware.',
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _laserOcupado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _cabecalho(),
          const SizedBox(height: 14),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 7, child: _painelCamera()),
                const SizedBox(width: 14),
                Expanded(flex: 3, child: _painelControle()),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _rodape(),
        ],
      ),
    );
  }

  Widget _cabecalho() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Image.asset(
            'assets/logo.png',
            height: 46,
            errorBuilder: (_, __, ___) => const Icon(
              Icons.eco,
              size: 40,
              color: kVerde,
            ),
          ),
          const SizedBox(width: 14),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AGROVISION',
                style: TextStyle(
                  color: kVerdeEscuro,
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              Text(
                'Monitoramento inteligente de plantas',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
          const Spacer(),
          _indicadorConexao(),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Configurar servidor',
            onPressed: widget.onConfigurar,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }

  Widget _indicadorConexao() {
    final cor = !_servidorOnline ? Colors.red : kVerde;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cor.withAlpha(22),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, color: cor, size: 9),
          const SizedBox(width: 7),
          Text(
            _servidorOnline ? 'SERVIDOR ONLINE' : 'SERVIDOR OFFLINE',
            style: TextStyle(
              color: cor,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _painelCamera() {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF172019),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_frame != null)
            Image.memory(
              _frame!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            )
          else
            const Center(
              child: Icon(
                Icons.videocam_outlined,
                color: Colors.white30,
                size: 64,
              ),
            ),
          Positioned(
            left: 14,
            top: 14,
            child: _etiqueta(
              _reconhecimentoAtivo ? 'RECONHECIMENTO ATIVO' : 'CÂMERA',
              _reconhecimentoAtivo ? kVerde : Colors.black54,
            ),
          ),
          if (!_reconhecimentoAtivo)
            Center(
              child: Container(
                padding: const EdgeInsets.all(18),
                margin: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(180),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  !_servidorOnline
                      ? 'Aguardando conexão com o servidor'
                      : _status == 'Erro na camera'
                          ? 'Não foi possível abrir a câmera'
                          : _status == 'Erro'
                              ? 'Erro no reconhecimento'
                              : 'Reconhecimento desativado\nPressione INICIAR para começar',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Row(
              children: [
                Expanded(
                  child: _estatistica(
                    'ERVAS DANINHAS',
                    '$_ervas',
                    Icons.grass,
                    const Color(0xFF63D471),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _estatistica(
                    'PLANTAS',
                    '$_plantas',
                    Icons.eco,
                    const Color(0xFFFF8A65),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _estatistica(
                    'FPS',
                    _fps.toStringAsFixed(1),
                    Icons.speed,
                    Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _painelControle() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'CONTROLE',
            style: TextStyle(
              color: kVerdeEscuro,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Gerencie a análise da câmera e o laser.',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kFundo,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(
                  _reconhecimentoAtivo ? Icons.radar : Icons.pause_circle,
                  color: _reconhecimentoAtivo ? kVerde : Colors.grey,
                  size: 28,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Status atual',
                        style: TextStyle(
                          color: Colors.black54,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        _status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: !_servidorOnline ||
                      _ocupado ||
                      _reconhecimentoAtivo
                  ? null
                  : () => _enviarComando('start'),
              icon: _ocupado
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: const Text(
                'INICIAR RECONHECIMENTO',
                textAlign: TextAlign.center,
              ),
              style: FilledButton.styleFrom(
                backgroundColor: kVerde,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: !_servidorOnline ||
                      _ocupado ||
                      !_reconhecimentoAtivo
                  ? null
                  : () => _enviarComando('stop'),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('PARAR RECONHECIMENTO'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade700,
                side: BorderSide(color: Colors.red.shade200),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Botão de laser: depende dos endpoints do servidor Python.
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: !_servidorOnline || _laserOcupado
                  ? null
                  : _alternarLaser,
              icon: _laserOcupado
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _laserAtivo ? Icons.flashlight_off : Icons.flash_on,
                    ),
              label: Text(
                _laserOcupado
                    ? 'AGUARDE...'
                    : _laserAtivo
                        ? 'DESLIGAR LASER'
                        : 'ATIVAR LASER',
                textAlign: TextAlign.center,
              ),
              style: FilledButton.styleFrom(
                backgroundColor:
                    _laserAtivo ? Colors.red.shade700 : const Color(0xFFB3261E),
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'O funcionamento físico depende da conexão com o controlador do robô.',
            style: TextStyle(color: Colors.black54, fontSize: 10),
          ),
          const SizedBox(height: 8),
          if (_erro != null)
            Text(
              _erro!,
              style: const TextStyle(
                color: Colors.red,
                fontSize: 11,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _estatistica(
    String titulo,
    String valor,
    IconData icone,
    Color cor,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(185),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icone, color: cor, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  valor,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _etiqueta(String texto, Color cor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cor,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        texto,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _rodape() {
    return Row(
      children: [
        const Icon(Icons.eco, color: kVerde, size: 17),
        const SizedBox(width: 6),
        const Text(
          'AGROVISION • FIAP',
          style: TextStyle(
            color: kVerdeEscuro,
            fontWeight: FontWeight.bold,
            fontSize: 11,
          ),
        ),
        const Spacer(),
        Text(
          'Servidor: ${widget.baseUrl}',
          style: const TextStyle(color: Colors.black45, fontSize: 10),
        ),
      ],
    );
  }
}
