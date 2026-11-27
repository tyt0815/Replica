import 'package:material_ui/material_ui.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import 'search.dart';
import 'update_screen.dart';

void main() => runApp(const ReplicaApp());

class ReplicaApp extends StatelessWidget {
  const ReplicaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Replica',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xffff0035),
      brightness: Brightness.dark,
    ),
    home: const SearchScreen(),
  );
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final input = TextEditingController();
  List<Track> tracks = [];
  String? message;
  bool busy = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkUpdate(context, manual: false);
    });
  }

  Future<void> search(String value) async {
    final query = value.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    final request = ++generation;
    setState(() {
      busy = true;
      message = null;
      tracks = [];
    });
    try {
      final results = await searchVideos(query);
      if (!mounted || request != generation) return;
      setState(() {
        tracks = results;
        if (results.isEmpty) message = '검색 결과가 없습니다.';
      });
    } catch (error) {
      if (!mounted || request != generation) return;
      setState(() => message = '검색 실패 · $error');
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        IconButton(
          tooltip: '설정',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
      title: const Text(
        'Replica',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: TextField(
              controller: input,
              textInputAction: TextInputAction.search,
              onSubmitted: search,
              decoration: InputDecoration(
                labelText: '음악 · 영상 검색',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: '검색',
                  icon: const Icon(Icons.search),
                  onPressed: () => search(input.text),
                ),
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (message != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(message!)),
          if (!busy && tracks.isEmpty && message == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: ['Jazz', 'K-pop', '클래식']
                    .map(
                      (word) => ActionChip(
                        label: Text(word),
                        onPressed: () {
                          input.text = word;
                          search(word);
                        },
                      ),
                    )
                    .toList(),
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (_, index) {
                final track = tracks[index];
                return ListTile(
                  leading: SizedBox(
                    width: 76,
                    child: Image.network(
                      track.thumbnail,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(Icons.music_note),
                    ),
                  ),
                  title: Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => WatchScreen(track: track),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.track});
  final Track track;
  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  late final player = YoutubePlayerController.fromVideoId(
    videoId: widget.track.id,
    autoPlay: true,
    params: const YoutubePlayerParams(showFullscreenButton: true),
  );

  @override
  void dispose() {
    player.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('재생')),
    body: ListView(
      children: [
        YoutubePlayer(controller: player),
        ListTile(
          title: Text(widget.track.title),
          subtitle: Text(widget.track.artist),
        ),
      ],
    ),
  );
}
