import 'dart:typed_data';


class NmeaBuffer {

  static const _maxLength = 1024 * 1024;
  // See [Gdl90Buffer]: bytes before [_read] are consumed, and the prefix is
  // dropped in one pass rather than memmoved on every extracted sentence.
  static const _compactThreshold = 64 * 1024;
  final List<int> _buffer = List.empty(growable: true);
  int _read = 0;

  int get _available => _buffer.length - _read;

  // not thread safe
  void put(Uint8List data) {
    if(_available > _maxLength) {
      _buffer.clear(); // this should not happen
      _read = 0;
      return;
    }
    if (_read >= _compactThreshold) {
      _buffer.removeRange(0, _read);
      _read = 0;
    }
    _buffer.addAll(data);
  }

  int _indexOf(int value, int from) {
    for (int i = from; i < _buffer.length; i++) {
      if (_buffer[i] == value) {
        return i;
      }
    }
    return -1;
  }

  Uint8List? get() {

    // find $ to LF
    // start
    int start = _indexOf(0x24, _read);
    if(start == -1) {
      // No sentence start anywhere; drop rather than re-scan. Without this a
      // GDL90 source feeding this buffer grows it until the 1MB clear().
      _read = _buffer.length;
      return null;
    }

    // skip all $ that follow start
    while(_buffer[start] == 0x24) {
      start++;
      if(start == _buffer.length) {
        return null;
      }
    }
    start--; //keep $

    int end = _indexOf(0x0a, start);
    if(end == -1) {
      return null;
    }

    final Uint8List data = Uint8List(end + 1 - start);
    for(int i = 0; i < data.length; i++) {
      data[i] = _buffer[start + i];
    }

    // consume through the LF, discarding any leading garbage
    _read = end + 1;

    return data;
  }
}
