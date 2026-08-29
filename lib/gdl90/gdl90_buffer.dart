import 'dart:typed_data';


class Gdl90Buffer {

  static const _maxLength = 1024 * 1024;
  // Bytes before [_read] are consumed. Compacting on every extracted frame was
  // an O(n) memmove, which made draining a backlog quadratic (a 30k-frame
  // backlog measured at ~12s); the consumed prefix is now dropped in one pass
  // only once it grows past this threshold.
  static const _compactThreshold = 64 * 1024;
  final List<int> _buffer = List.empty(growable: true);
  int _read = 0;

  int get _available => _buffer.length - _read;

  // not thread safe
  void put(Uint8List data) {
    if (_available > _maxLength) {
      _buffer.clear(); // sync lost; keep processing new bytes
      _read = 0;
    }
    if (_read >= _compactThreshold) {
      _buffer.removeRange(0, _read);
      _read = 0;
    }
    _buffer.addAll(data);
  }

  // Scans from [from] rather than from index 0, so a partial frame at the head
  // is not re-scanned from the start of the buffer on every call.
  int _indexOf(int value, int from) {
    for (int i = from; i < _buffer.length; i++) {
      if (_buffer[i] == value) {
        return i;
      }
    }
    return -1;
  }

  Uint8List? get() {

    // find 0x7e to 0x7e
    // start
    int start = _indexOf(0x7e, _read);
    if(start == -1) {
      // No frame delimiter anywhere, so none of these bytes can begin a frame.
      // Drop them instead of re-scanning every tick -- this is what let the
      // buffer grow to _maxLength when the connected source was not GDL90.
      _read = _buffer.length;
      return null;
    }

    // skip all 7e that follow start
    while(_buffer[start] == 0x7e) {
      start++;
      if(start == _buffer.length) {
        return null;
      }
    }

    int end = _indexOf(0x7e, start);
    if(end == -1) {
      return null;
    }

    final Uint8List data = Uint8List(end - start);
    for(int i = 0; i < data.length; i++) {
      data[i] = _buffer[start + i];
    }

    // consume through the closing delimiter, discarding any leading garbage
    _read = end + 1;

    return data;
  }
}
