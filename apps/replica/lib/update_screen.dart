import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart';

import 'update.dart';

Future<void> checkUpdate(BuildContext context, {required bool manual}) async {
  final client = http.Client();
  try {
    final info = await PackageInfo.fromPlatform();
    final release = await latestRelease(client, Version.parse(info.version));
    if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (release == null) {
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('현재 버전 ${info.version}이 최신입니다.')),
        );
      }
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(release: release),
    );
  } catch (_) {
    if (manual && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('업데이트를 확인하지 못했습니다. 잠시 후 다시 시도하세요.')),
      );
    }
  } finally {
    client.close();
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool checking = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('설정')),
    body: ListTile(
      title: const Text('앱 업데이트 확인'),
      subtitle: Text(checking ? '확인 중…' : 'GitHub Releases'),
      enabled: !checking,
      onTap: () async {
        setState(() => checking = true);
        try {
          await checkUpdate(context, manual: true);
        } finally {
          if (mounted) setState(() => checking = false);
        }
      },
    ),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.release});
  final AppRelease release;
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  final client = http.Client();
  double? progress;
  String? error;
  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  Future<void> install() async {
    setState(() {
      progress = 0;
      error = null;
    });
    try {
      final directory = await getTemporaryDirectory();
      if (!mounted) return;
      final file = await downloadRelease(client, widget.release, directory, (
        value,
      ) {
        if (mounted &&
            (value * 100).floor() != ((progress ?? 0) * 100).floor()) {
          setState(() => progress = value);
        }
      });
      if (!mounted) return;
      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) throw StateError(result.message);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          progress = null;
          error = '다운로드 또는 설치를 시작하지 못했습니다.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Replica ${widget.release.version} 업데이트'),
    content: progress == null
        ? Text(error ?? '새 버전을 다운로드하고 설치할까요?')
        : LinearProgressIndicator(value: progress),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      if (progress == null)
        FilledButton(onPressed: install, child: const Text('다운로드 및 설치')),
    ],
  );
}
