import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const PhrasesFtpApp());

class PhrasesFtpApp extends StatelessWidget {
  const PhrasesFtpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phrases SFTP',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// Nombre remoto del archivo según la fecha: IMG_AAAAMMDD-hhmmss.jpg.
/// Ej.: 14/10/2026 10:34:56 -> "IMG_20261014-103456.jpg"
String remoteFileName(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  final h = date.hour.toString().padLeft(2, '0');
  final min = date.minute.toString().padLeft(2, '0');
  final s = date.second.toString().padLeft(2, '0');
  return 'IMG_$y$m$d-$h$min$s.jpg';
}

const languages = ['es', 'en', 'pt'];

/// Configuración del servidor FTP, persistida en el dispositivo.
class FtpSettings {
  String host;
  int port;
  String user;
  String password;

  /// Carpeta remota de cada idioma (es, en, pt).
  Map<String, String> folders;

  FtpSettings({
    this.host = '',
    this.port = 22,
    this.user = '',
    this.password = '',
    Map<String, String>? folders,
  }) : folders = folders ?? {};

  bool get isComplete => host.isNotEmpty && user.isNotEmpty;

  /// Carpeta del idioma, o null si no está configurada.
  String? folderFor(String lang) {
    final folder = folders[lang]?.trim() ?? '';
    return folder.isEmpty ? null : folder;
  }

  static Future<FtpSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return FtpSettings(
      host: prefs.getString('ftp_host') ?? '',
      port: prefs.getInt('ftp_port') ?? 22,
      user: prefs.getString('ftp_user') ?? '',
      password: prefs.getString('ftp_password') ?? '',
      folders: {
        for (final lang in languages)
          lang: prefs.getString('ftp_folder_$lang') ?? '',
      },
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ftp_host', host);
    await prefs.setInt('ftp_port', port);
    await prefs.setString('ftp_user', user);
    await prefs.setString('ftp_password', password);
    for (final lang in languages) {
      await prefs.setString('ftp_folder_$lang', folders[lang] ?? '');
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  File? _file;
  String? _language;
  bool _uploading = false;

  /// Mensaje de resultado mostrado abajo de la pantalla (verde/rojo).
  String? _status;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    // Imagen compartida mientras la app ya estaba abierta.
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _onShared,
    );
    // Imagen compartida que abrió la app.
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _onShared(files);
      ReceiveSharingIntent.instance.reset();
    });
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  Future<void> _onShared(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;
    setState(() {
      _file = File(files.first.path);
      _language = null;
      _status = null;
    });
  }

  Future<void> _onLanguageSelected(String? lang) async {
    if (lang == null || _file == null || _uploading) return;
    setState(() {
      _language = lang;
      _uploading = true;
      _status = null;
    });

    final settings = await FtpSettings.load();
    String message;
    bool ok = false;
    if (!settings.isComplete) {
      message = 'Configura el servidor SFTP primero (icono ⚙).';
    } else if (settings.folderFor(lang) == null) {
      message = 'Configura la carpeta SFTP para "$lang" (icono ⚙).';
    } else {
      try {
        final remoteName = remoteFileName(DateTime.now());
        ok = await _upload(settings, _file!, lang, remoteName);
        message = ok
            ? 'Archivo $remoteName subido a ${settings.folderFor(lang)} con éxito'
            : 'Falló la transferencia SFTP';
      } catch (e) {
        message = 'Falló la transferencia SFTP: $e';
      }
    }

    if (!mounted) return;
    setState(() {
      _uploading = false;
      _status = message;
      _statusOk = ok;
    });

    // Transferencia exitosa: se muestra el mensaje un momento y la app se cierra.
    if (ok) {
      await Future.delayed(const Duration(seconds: 2));
      await SystemNavigator.pop();
    }
  }

  Future<bool> _upload(
    FtpSettings s,
    File file,
    String lang,
    String remoteName,
  ) async {
    final sftp = SFTPConnect(
      s.host,
      port: s.port,
      user: s.user,
      pass: s.password,
      timeout: 30,
    );
    try {
      if (!await sftp.connect()) return false;
      //await sftp.setTransferType(TransferType.binary);
      final remoteDir = s.folderFor(lang)!;
      //if (!await sftp.createFolderIfNotExist(remoteDir)) return false;
      if (!await sftp.changeDirectory(remoteDir)) return false;
      return await sftp.uploadFile(file, sRemoteName: remoteName);
    } finally {
      try {
        await sftp.disconnect();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Phrases SFTP'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Configuración SFTP',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: _file == null ? _buildEmpty() : _buildShared(),
      bottomNavigationBar: _status == null ? null : _buildStatus(),
    );
  }

  Widget _buildStatus() {
    return Container(
      color: _statusOk ? Colors.green[700] : Colors.red[700],
      padding: const EdgeInsets.all(16),
      child: SafeArea(
        top: false,
        child: Text(
          _status!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Comparte una imagen desde WhatsApp (u otra app) '
          'y elige "Phrases SFTP".',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildShared() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(_file!, height: 240, fit: BoxFit.contain),
        ),
        const SizedBox(height: 12),
        Text(
          remoteFileName(DateTime.now()),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        const Text('Selecciona el idioma para subir el archivo:'),
        RadioGroup<String>(
          groupValue: _language,
          onChanged: _uploading ? (_) {} : _onLanguageSelected,
          child: Column(
            children: [
              for (final lang in languages)
                RadioListTile<String>(
                  title: Text(lang),
                  value: lang,
                  enabled: !_uploading,
                ),
            ],
          ),
        ),
        if (_uploading)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _folders = {
    for (final lang in languages) lang: TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    FtpSettings.load().then((s) {
      _host.text = s.host;
      _port.text = s.port.toString();
      _user.text = s.user;
      _password.text = s.password;
      for (final lang in languages) {
        _folders[lang]!.text = s.folders[lang] ?? '';
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _password, ..._folders.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    await FtpSettings(
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      user: _user.text.trim(),
      password: _password.text,
      folders: {
        for (final lang in languages) lang: _folders[lang]!.text.trim(),
      },
    ).save();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Configuración guardada')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuración SFTP')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _host,
            decoration: const InputDecoration(labelText: 'Servidor (host)'),
            keyboardType: TextInputType.url,
          ),
          TextField(
            controller: _port,
            decoration: const InputDecoration(labelText: 'Puerto'),
            keyboardType: TextInputType.number,
          ),
          TextField(
            controller: _user,
            decoration: const InputDecoration(labelText: 'Usuario'),
          ),
          TextField(
            controller: _password,
            decoration: const InputDecoration(labelText: 'Contraseña'),
            obscureText: true,
          ),
          const SizedBox(height: 24),
          Text(
            'Carpeta SFTP de cada idioma',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final lang in languages)
            TextField(
              controller: _folders[lang],
              decoration: InputDecoration(
                labelText: 'Carpeta para "$lang"',
                hintText: '/ruta/en/el/servidor',
              ),
            ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Guardar')),
        ],
      ),
    );
  }
}
