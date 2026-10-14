import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const PhrasesFtpApp());

class PhrasesFtpApp extends StatelessWidget {
  const PhrasesFtpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phrases FTP',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// Reemplaza el primer guión "-" del nombre de archivo por un guión bajo "_".
/// Ej.: "IMG-20261014-WA0001.jpg" -> "IMG_20261014-WA0001.jpg"
String renameFirstDash(String fileName) => fileName.replaceFirst('-', '_');

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
    this.port = 21,
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
      port: prefs.getInt('ftp_port') ?? 21,
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
    final original = File(files.first.path);
    final newName = renameFirstDash(p.basename(original.path));
    final renamed = await original.copy(p.join(original.parent.path, newName));
    if (renamed.path != original.path) {
      try {
        await original.delete();
      } catch (_) {}
    }
    setState(() {
      _file = renamed;
      _language = null;
    });
  }

  Future<void> _onLanguageSelected(String? lang) async {
    if (lang == null || _file == null || _uploading) return;
    setState(() {
      _language = lang;
      _uploading = true;
    });

    final settings = await FtpSettings.load();
    String message;
    bool ok = false;
    if (!settings.isComplete) {
      message = 'Configura el servidor FTP primero (icono ⚙).';
    } else if (settings.folderFor(lang) == null) {
      message = 'Configura la carpeta FTP para "$lang" (icono ⚙).';
    } else {
      try {
        ok = await _upload(settings, _file!, lang);
        message = ok
            ? 'Archivo ${p.basename(_file!.path)} subido a ${settings.folderFor(lang)} con éxito'
            : 'Falló la transferencia FTP';
      } catch (e) {
        message = 'Falló la transferencia FTP: $e';
      }
    }

    if (!mounted) return;
    setState(() => _uploading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: ok ? Colors.green[700] : Colors.red[700],
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<bool> _upload(FtpSettings s, File file, String lang) async {
    final ftp = FTPConnect(
      s.host,
      port: s.port,
      user: s.user,
      pass: s.password,
      timeout: 30,
    );
    try {
      if (!await ftp.connect()) return false;
      await ftp.setTransferType(TransferType.binary);
      final remoteDir = s.folderFor(lang)!;
      if (!await ftp.createFolderIfNotExist(remoteDir)) return false;
      if (!await ftp.changeDirectory(remoteDir)) return false;
      return await ftp.uploadFile(file, sRemoteName: p.basename(file.path));
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Phrases FTP'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Configuración FTP',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: _file == null ? _buildEmpty() : _buildShared(),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Comparte una imagen desde WhatsApp (u otra app) '
          'y elige "Phrases FTP".',
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
          p.basename(_file!.path),
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
      port: int.tryParse(_port.text.trim()) ?? 21,
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
      appBar: AppBar(title: const Text('Configuración FTP')),
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
            'Carpeta FTP de cada idioma',
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
