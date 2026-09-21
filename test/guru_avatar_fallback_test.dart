import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

void main() {
  test('catalog without avatar still resolves canonical local portrait', () {
    for (final id in [
      'bill-ackman',
      'li-lu',
      'warren-buffett',
      'william-heard',
      'evan-mcgoff',
      'michael-cuggino',
      'john-stamas',
    ]) {
      expect(
        resolvedGuruAvatarUrl({'id': id, 'avatarUrl': null}),
        '/guru-avatars/$id.png?v=144-20260912r2',
      );
    }
  });
  test('preserves supplied portrait and handles both API field names', () {
    expect(
      resolvedGuruAvatarUrl({'id': 'bill-ackman', 'avatar': '/custom.png'}),
      '/custom.png',
    );
    expect(
      resolvedGuruAvatarUrl({
        'avatarUrl': '/first.png',
        'avatar': '/second.png',
      }),
      '/first.png',
    );
    expect(
      resolvedGuruAvatarUrl({'guruId': 'li-lu', 'avatarUrl': ''}),
      '/guru-avatars/li-lu.png?v=144-20260912r2',
    );
  });
  test('missing or unsafe identity stays an initial, not an invented path', () {
    expect(resolvedGuruAvatarUrl({'name': 'Unknown'}), '');
    expect(resolvedGuruAvatarUrl({'id': '../other'}), '');
  });
}
