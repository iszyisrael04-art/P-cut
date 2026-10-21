class SubtitleCue {
  const SubtitleCue({
    required this.id,
    required this.start,
    required this.end,
    required this.text,
  });
  final String id, text;
  final double start, end;
  bool active(double t) => t >= start && t < end;
  Map<String, dynamic> toJson() => {
    'id': id,
    'start': start,
    'end': end,
    'text': text,
  };
  factory SubtitleCue.fromJson(Map m) => SubtitleCue(
    id: m['id'],
    start: (m['start'] as num).toDouble(),
    end: (m['end'] as num).toDouble(),
    text: m['text'],
  );
}

double parseSubtitleTime(String text) {
  final match = RegExp(
    r'^(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})$',
  ).firstMatch(text.trim());
  if (match == null)
    throw const FormatException('Subtitle timestamps must use HH:MM:SS,mmm.');
  final p = [for (var i = 1; i <= 4; i++) int.parse(match.group(i)!)];
  if (p[1] >= 60 || p[2] >= 60)
    throw const FormatException('Invalid subtitle timestamp.');
  return p[0] * 3600 + p[1] * 60 + p[2] + p[3] / 1000;
}

List<SubtitleCue> parseSrt(String input, {String prefix = 'caption'}) {
  final text = input
      .replaceAll('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .trim();
  if (text.isEmpty) return [];
  final cues = <SubtitleCue>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    final index = lines.indexWhere((l) => l.contains('-->'));
    if (index < 0 || index + 1 >= lines.length)
      throw const FormatException('A subtitle block has no timing or text.');
    final times = lines[index].split('-->');
    if (times.length != 2)
      throw const FormatException('Invalid subtitle interval.');
    final start = parseSubtitleTime(times[0]),
        end = parseSubtitleTime(times[1]);
    final body = lines
        .skip(index + 1)
        .join('\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    if (end <= start ||
        start < 0 ||
        end > 1800 ||
        body.isEmpty ||
        body.length > 300)
      throw const FormatException(
        'Subtitle text or timing is invalid. Use up to 300 characters and a 30-minute timeline.',
      );
    cues.add(
      SubtitleCue(
        id: '$prefix-${cues.length}',
        start: start,
        end: end,
        text: body,
      ),
    );
    if (cues.length > 500)
      throw const FormatException('Use up to 500 subtitle cues per project.');
  }
  cues.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < cues.length; i++) {
    if (cues[i].start < cues[i - 1].end - .001)
      throw const FormatException(
        'Overlapping subtitle cues must be corrected before import.',
      );
  }
  return cues;
}

String subtitleTime(double t) {
  final ms = (t * 1000).round();
  return '${(ms ~/ 3600000).toString().padLeft(2, '0')}:${((ms ~/ 60000) % 60).toString().padLeft(2, '0')}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')},${(ms % 1000).toString().padLeft(3, '0')}';
}

String writeSrt(List<SubtitleCue> cues) => cues.indexed
    .map(
      (e) =>
          '${e.$1 + 1}\n${subtitleTime(e.$2.start)} --> ${subtitleTime(e.$2.end)}\n${e.$2.text}\n',
    )
    .join('\n');
