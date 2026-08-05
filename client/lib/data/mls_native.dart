import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int yappaMlsAbiVersion = 4;

final class _NativeBuffer extends Struct {
  external Pointer<Uint8> data;

  @UintPtr()
  external int length;
}

final class _NativeResult extends Struct {
  @Int32()
  external int code;

  @Uint64()
  external int value;

  external _NativeBuffer buffer;
}

typedef _AbiVersionNative = Uint32 Function();
typedef _AbiVersionDart = int Function();
typedef _BufferFreeNative = Void Function(_NativeBuffer);
typedef _BufferFreeDart = void Function(_NativeBuffer);
typedef _DeviceNewNative = Pointer<Void> Function(Pointer<Uint8>, UintPtr);
typedef _DeviceNewDart = Pointer<Void> Function(Pointer<Uint8>, int);
typedef _DeviceImportNative =
    Pointer<Void> Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
      UintPtr,
    );
typedef _DeviceImportDart =
    Pointer<Void> Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
    );
typedef _DeviceFreeNative = Void Function(Pointer<Void>);
typedef _NoInputNative = _NativeResult Function(Pointer<Void>);
typedef _NoInputDart = _NativeResult Function(Pointer<Void>);
typedef _OneInputNative =
    _NativeResult Function(Pointer<Void>, Pointer<Uint8>, UintPtr);
typedef _OneInputDart =
    _NativeResult Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _TwoInputNative =
    _NativeResult Function(
      Pointer<Void>,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
      UintPtr,
    );
typedef _TwoInputDart =
    _NativeResult Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
    );
typedef _ExportNative =
    _NativeResult Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      UintPtr,
    );
typedef _ExportDart =
    _NativeResult Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, int);

class MlsNativeException implements Exception {
  final String message;

  const MlsNativeException(this.message);

  @override
  String toString() => message;
}

class MlsPreparedCommit {
  final int parentEpoch;
  final int acceptedEpoch;
  final Uint8List commit;

  const MlsPreparedCommit({
    required this.parentEpoch,
    required this.acceptedEpoch,
    required this.commit,
  });
}

class MlsPreparedAdd extends MlsPreparedCommit {
  final Uint8List welcome;

  const MlsPreparedAdd({
    required super.parentEpoch,
    required super.acceptedEpoch,
    required super.commit,
    required this.welcome,
  });
}

class MlsDecryptedApplication {
  final int epoch;
  final Uint8List senderCredential;
  final Uint8List senderSignaturePublicKey;
  final Uint8List plaintext;

  const MlsDecryptedApplication({
    required this.epoch,
    required this.senderCredential,
    required this.senderSignaturePublicKey,
    required this.plaintext,
  });
}

class MlsGroupMember {
  final Uint8List credential;
  final Uint8List signaturePublicKey;

  const MlsGroupMember({
    required this.credential,
    required this.signaturePublicKey,
  });
}

class MlsOutgoingApplication {
  final Uint8List groupId;
  final String operationId;
  final int epoch;
  final Uint8List plaintext;
  final Uint8List wire;

  const MlsOutgoingApplication({
    required this.groupId,
    required this.operationId,
    required this.epoch,
    required this.plaintext,
    required this.wire,
  });
}

class _Cursor {
  final Uint8List bytes;
  int offset = 0;

  _Cursor(this.bytes);

  int uint32() {
    _require(4);
    final value = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    offset += 4;
    return value;
  }

  int uint64() {
    _require(8);
    final value = ByteData.sublistView(bytes, offset, offset + 8).getUint64(0);
    offset += 8;
    return value;
  }

  Uint8List value({required int max}) {
    final length = uint32();
    if (length > max) {
      throw const MlsNativeException('The MLS bridge returned oversized data.');
    }
    _require(length);
    final value = Uint8List.fromList(bytes.sublist(offset, offset + length));
    offset += length;
    return value;
  }

  void finish() {
    if (offset != bytes.length) {
      throw const MlsNativeException('The MLS bridge returned trailing data.');
    }
  }

  void _require(int count) {
    if (count < 0 || offset + count > bytes.length) {
      throw const MlsNativeException('The MLS bridge returned truncated data.');
    }
  }
}

class _MlsNativeLibrary {
  static final _MlsNativeLibrary instance = _MlsNativeLibrary._();

  late final DynamicLibrary library;
  late final _BufferFreeDart bufferFree;
  late final _DeviceNewDart deviceNew;
  late final _DeviceImportDart deviceImport;
  late final Pointer<NativeFunction<_DeviceFreeNative>> deviceFreePointer;
  late final _NoInputDart signaturePublicKey;
  late final _ExportDart exportState;
  late final _NoInputDart generateKeyPackage;
  late final _OneInputDart createGroup;
  late final _TwoInputDart prepareAdd;
  late final _OneInputDart prepareSelfUpdate;
  late final _TwoInputDart prepareRemove;
  late final _OneInputDart acceptPendingCommit;
  late final _OneInputDart rejectPendingCommit;
  late final _TwoInputDart joinWelcome;
  late final _TwoInputDart processCommit;
  late final _OneInputDart groupMembers;
  late final _TwoInputDart encryptApplication;
  late final _TwoInputDart decryptApplication;
  late final _TwoInputDart stageApplication;
  late final _TwoInputDart clearStagedApplication;
  late final _TwoInputDart stageOutgoingApplication;
  late final _NoInputDart pendingOutgoingApplications;
  late final _OneInputDart clearOutgoingApplication;
  late final _OneInputDart epoch;

  _MlsNativeLibrary._() {
    library = _open();
    final version = library.lookupFunction<_AbiVersionNative, _AbiVersionDart>(
      'yappa_mls_abi_version',
    )();
    if (version != yappaMlsAbiVersion) {
      throw MlsNativeException(
        'The MLS bridge ABI is incompatible (expected '
        '$yappaMlsAbiVersion, received $version).',
      );
    }
    bufferFree = library.lookupFunction<_BufferFreeNative, _BufferFreeDart>(
      'yappa_mls_buffer_free',
    );
    deviceNew = library.lookupFunction<_DeviceNewNative, _DeviceNewDart>(
      'yappa_mls_device_new',
    );
    deviceImport = library
        .lookupFunction<_DeviceImportNative, _DeviceImportDart>(
          'yappa_mls_device_import',
        );
    deviceFreePointer = library.lookup<NativeFunction<_DeviceFreeNative>>(
      'yappa_mls_device_free',
    );
    signaturePublicKey = _noInput('yappa_mls_signature_public_key');
    exportState = library.lookupFunction<_ExportNative, _ExportDart>(
      'yappa_mls_export_state',
    );
    generateKeyPackage = _noInput('yappa_mls_generate_key_package');
    createGroup = _oneInput('yappa_mls_create_group');
    prepareAdd = _twoInput('yappa_mls_prepare_add');
    prepareSelfUpdate = _oneInput('yappa_mls_prepare_self_update');
    prepareRemove = _twoInput('yappa_mls_prepare_remove');
    acceptPendingCommit = _oneInput('yappa_mls_accept_pending_commit');
    rejectPendingCommit = _oneInput('yappa_mls_reject_pending_commit');
    joinWelcome = _twoInput('yappa_mls_join_welcome');
    processCommit = _twoInput('yappa_mls_process_commit');
    groupMembers = _oneInput('yappa_mls_group_members');
    encryptApplication = _twoInput('yappa_mls_encrypt_application');
    decryptApplication = _twoInput('yappa_mls_decrypt_application');
    stageApplication = _twoInput('yappa_mls_stage_application');
    clearStagedApplication = _twoInput('yappa_mls_clear_staged_application');
    stageOutgoingApplication = _twoInput(
      'yappa_mls_stage_outgoing_application',
    );
    pendingOutgoingApplications = _noInput(
      'yappa_mls_pending_outgoing_applications',
    );
    clearOutgoingApplication = _oneInput(
      'yappa_mls_clear_outgoing_application',
    );
    epoch = _oneInput('yappa_mls_epoch');
  }

  _NoInputDart _noInput(String symbol) =>
      library.lookupFunction<_NoInputNative, _NoInputDart>(symbol);

  _OneInputDart _oneInput(String symbol) =>
      library.lookupFunction<_OneInputNative, _OneInputDart>(symbol);

  _TwoInputDart _twoInput(String symbol) =>
      library.lookupFunction<_TwoInputNative, _TwoInputDart>(symbol);

  static DynamicLibrary _open() {
    final candidates = Platform.isWindows
        ? const [
            'yappa_mls.dll',
            r'native\yappa_mls\target\debug\yappa_mls.dll',
            r'native\yappa_mls\target\release\yappa_mls.dll',
          ]
        : Platform.isLinux
        ? const [
            'libyappa_mls.so',
            'native/yappa_mls/target/debug/libyappa_mls.so',
            'native/yappa_mls/target/release/libyappa_mls.so',
          ]
        : Platform.isMacOS
        ? [
            '${File(Platform.resolvedExecutable).parent.path}/'
                '../Frameworks/libyappa_mls.dylib',
            'libyappa_mls.dylib',
            'native/yappa_mls/target/debug/libyappa_mls.dylib',
            'native/yappa_mls/target/release/libyappa_mls.dylib',
          ]
        : const <String>[];
    Object? lastError;
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } catch (error) {
        lastError = error;
      }
    }
    throw MlsNativeException(
      'Yappa could not load its MLS cryptography library: $lastError',
    );
  }
}

final class MlsNativeDevice implements Finalizable {
  static const int _maxWireBytes = 1024 * 1024;
  static const int _maxApplicationBytes = 256 * 1024;
  static final NativeFinalizer _finalizer = NativeFinalizer(
    _MlsNativeLibrary.instance.deviceFreePointer.cast(),
  );

  final _MlsNativeLibrary _native;
  Pointer<Void> _handle;
  final Object _finalizerToken = Object();

  MlsNativeDevice._(this._native, this._handle) {
    _finalizer.attach(this, _handle, detach: _finalizerToken);
  }

  factory MlsNativeDevice.create(Uint8List identity) {
    final native = _MlsNativeLibrary.instance;
    final pointer = _copyInput(identity);
    try {
      final handle = native.deviceNew(pointer, identity.length);
      if (handle == nullptr) {
        throw const MlsNativeException('Could not create the MLS device.');
      }
      return MlsNativeDevice._(native, handle);
    } finally {
      calloc.free(pointer);
    }
  }

  factory MlsNativeDevice.restore({
    required Uint8List wrappingKey,
    required Uint8List context,
    required Uint8List encryptedState,
  }) {
    if (wrappingKey.length != 32) {
      throw const MlsNativeException('The MLS wrapping key must be 32 bytes.');
    }
    final native = _MlsNativeLibrary.instance;
    final keyPointer = _copyInput(wrappingKey);
    final contextPointer = _copyInput(context);
    final statePointer = _copyInput(encryptedState);
    try {
      final handle = native.deviceImport(
        keyPointer,
        contextPointer,
        context.length,
        statePointer,
        encryptedState.length,
      );
      if (handle == nullptr) {
        throw const MlsNativeException('Could not restore the MLS device.');
      }
      return MlsNativeDevice._(native, handle);
    } finally {
      keyPointer
          .asTypedList(wrappingKey.length)
          .fillRange(0, wrappingKey.length, 0);
      calloc.free(keyPointer);
      calloc.free(contextPointer);
      calloc.free(statePointer);
    }
  }

  Uint8List get signaturePublicKey =>
      _bytesResult(_native.signaturePublicKey(_liveHandle));

  Uint8List generateKeyPackage() =>
      _bytesResult(_native.generateKeyPackage(_liveHandle));

  Uint8List exportState({
    required Uint8List wrappingKey,
    required Uint8List context,
  }) {
    if (wrappingKey.length != 32) {
      throw const MlsNativeException('The MLS wrapping key must be 32 bytes.');
    }
    final keyPointer = _copyInput(wrappingKey);
    final contextPointer = _copyInput(context);
    try {
      return _bytesResult(
        _native.exportState(
          _liveHandle,
          keyPointer,
          contextPointer,
          context.length,
        ),
      );
    } finally {
      keyPointer.asTypedList(32).fillRange(0, 32, 0);
      calloc.free(keyPointer);
      calloc.free(contextPointer);
    }
  }

  int createGroup(Uint8List groupId) => _valueOne(_native.createGroup, groupId);

  int acceptPendingCommit(Uint8List groupId) =>
      _valueOne(_native.acceptPendingCommit, groupId);

  int rejectPendingCommit(Uint8List groupId) =>
      _valueOne(_native.rejectPendingCommit, groupId);

  int epoch(Uint8List groupId) => _valueOne(_native.epoch, groupId);

  MlsPreparedAdd prepareAdd(Uint8List groupId, Uint8List keyPackage) {
    final bytes = _bytesTwo(_native.prepareAdd, groupId, keyPackage);
    final cursor = _Cursor(bytes);
    final value = MlsPreparedAdd(
      parentEpoch: cursor.uint64(),
      acceptedEpoch: cursor.uint64(),
      commit: cursor.value(max: _maxWireBytes),
      welcome: cursor.value(max: _maxWireBytes),
    );
    cursor.finish();
    return value;
  }

  MlsPreparedCommit prepareSelfUpdate(Uint8List groupId) =>
      _preparedCommit(_bytesOne(_native.prepareSelfUpdate, groupId));

  MlsPreparedCommit prepareRemove(Uint8List groupId, Uint8List credential) =>
      _preparedCommit(_bytesTwo(_native.prepareRemove, groupId, credential));

  int joinWelcome(Uint8List groupId, Uint8List welcome) =>
      _valueTwo(_native.joinWelcome, groupId, welcome);

  int processCommit(Uint8List groupId, Uint8List commit) =>
      _valueTwo(_native.processCommit, groupId, commit);

  List<MlsGroupMember> groupMembers(Uint8List groupId) {
    final bytes = _bytesOne(_native.groupMembers, groupId);
    final cursor = _Cursor(bytes);
    final count = cursor.uint32();
    if (count < 1 || count > 10000) {
      throw const MlsNativeException(
        'The MLS bridge returned an invalid member count.',
      );
    }
    final members = List<MlsGroupMember>.generate(count, (_) {
      final credential = cursor.value(max: 1024);
      final signaturePublicKey = cursor.value(max: 32);
      if (credential.isEmpty || signaturePublicKey.length != 32) {
        throw const MlsNativeException(
          'The MLS bridge returned an invalid member.',
        );
      }
      return MlsGroupMember(
        credential: credential,
        signaturePublicKey: signaturePublicKey,
      );
    }, growable: false);
    cursor.finish();
    return members;
  }

  Uint8List encryptApplication(Uint8List groupId, Uint8List plaintext) {
    if (plaintext.length > _maxApplicationBytes) {
      throw const MlsNativeException('The MLS application data is too large.');
    }
    return _bytesTwo(_native.encryptApplication, groupId, plaintext);
  }

  MlsDecryptedApplication decryptApplication(
    Uint8List groupId,
    Uint8List wire,
  ) => _decodeApplication(_bytesTwo(_native.decryptApplication, groupId, wire));

  MlsDecryptedApplication stageApplication(
    Uint8List groupId,
    int serverSequence,
    Uint8List wire,
  ) {
    if (serverSequence < 1) {
      throw const MlsNativeException('Invalid MLS server sequence.');
    }
    final sequence = ByteData(8)..setUint64(0, serverSequence);
    return _decodeApplication(
      _bytesTwo(
        _native.stageApplication,
        groupId,
        Uint8List.fromList([...sequence.buffer.asUint8List(), ...wire]),
      ),
    );
  }

  int clearStagedApplication(Uint8List groupId, int serverSequence) {
    if (serverSequence < 1) {
      throw const MlsNativeException('Invalid MLS server sequence.');
    }
    final sequence = ByteData(8)..setUint64(0, serverSequence);
    return _valueTwo(
      _native.clearStagedApplication,
      groupId,
      sequence.buffer.asUint8List(),
    );
  }

  MlsOutgoingApplication stageOutgoingApplication(
    Uint8List groupId,
    String operationId,
    Uint8List plaintext,
  ) {
    final operation = Uint8List.fromList(ascii.encode(operationId));
    if (!RegExp(r'^mlsop_[A-Za-z0-9_-]{22}$').hasMatch(operationId) ||
        plaintext.isEmpty ||
        plaintext.length > _maxApplicationBytes) {
      throw const MlsNativeException('Invalid outgoing MLS application.');
    }
    return _decodeOutgoing(
      _bytesTwo(
        _native.stageOutgoingApplication,
        groupId,
        Uint8List.fromList([...operation, ...plaintext]),
      ),
    );
  }

  List<MlsOutgoingApplication> pendingOutgoingApplications() {
    final cursor = _Cursor(
      _bytesResult(_native.pendingOutgoingApplications(_liveHandle)),
    );
    final count = cursor.uint32();
    if (count > 1000) {
      throw const MlsNativeException(
        'The MLS bridge returned too many outgoing applications.',
      );
    }
    final values = List<MlsOutgoingApplication>.generate(
      count,
      (_) => _decodeOutgoing(
        cursor.value(max: _maxWireBytes + _maxApplicationBytes + 4096),
      ),
      growable: false,
    );
    cursor.finish();
    return values;
  }

  void clearOutgoingApplication(String operationId) {
    if (!RegExp(r'^mlsop_[A-Za-z0-9_-]{22}$').hasMatch(operationId)) {
      throw const MlsNativeException('Invalid MLS operation id.');
    }
    _valueOne(
      _native.clearOutgoingApplication,
      Uint8List.fromList(ascii.encode(operationId)),
    );
  }

  MlsDecryptedApplication _decodeApplication(Uint8List bytes) {
    final cursor = _Cursor(bytes);
    final epoch = cursor.uint64();
    final senderCredential = cursor.value(max: 1024);
    final signaturePublicKey = cursor.value(max: 32);
    if (signaturePublicKey.length != 32) {
      throw const MlsNativeException(
        'The MLS bridge returned an invalid sender signature key.',
      );
    }
    final value = MlsDecryptedApplication(
      epoch: epoch,
      senderCredential: senderCredential,
      senderSignaturePublicKey: signaturePublicKey,
      plaintext: cursor.value(max: _maxApplicationBytes),
    );
    cursor.finish();
    return value;
  }

  MlsOutgoingApplication _decodeOutgoing(Uint8List bytes) {
    final cursor = _Cursor(bytes);
    final groupId = cursor.value(max: 1024);
    final operationBytes = cursor.value(max: 28);
    final epoch = cursor.uint64();
    final plaintext = cursor.value(max: _maxApplicationBytes);
    final wire = cursor.value(max: _maxWireBytes);
    cursor.finish();
    final operationId = ascii.decode(operationBytes);
    if (groupId.isEmpty ||
        !RegExp(r'^mlsop_[A-Za-z0-9_-]{22}$').hasMatch(operationId) ||
        plaintext.isEmpty ||
        wire.isEmpty) {
      throw const MlsNativeException(
        'The MLS bridge returned an invalid outgoing application.',
      );
    }
    return MlsOutgoingApplication(
      groupId: groupId,
      operationId: operationId,
      epoch: epoch,
      plaintext: plaintext,
      wire: wire,
    );
  }

  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(_finalizerToken);
    _native.deviceFreePointer.asFunction<void Function(Pointer<Void>)>()(
      _handle,
    );
    _handle = nullptr;
  }

  Pointer<Void> get _liveHandle {
    if (_handle == nullptr) {
      throw const MlsNativeException('The MLS device is closed.');
    }
    return _handle;
  }

  int _valueOne(_OneInputDart operation, Uint8List first) {
    final pointer = _copyInput(first);
    try {
      return _takeResult(operation(_liveHandle, pointer, first.length)).value;
    } finally {
      calloc.free(pointer);
    }
  }

  int _valueTwo(_TwoInputDart operation, Uint8List first, Uint8List second) {
    final firstPointer = _copyInput(first);
    final secondPointer = _copyInput(second);
    try {
      return _takeResult(
        operation(
          _liveHandle,
          firstPointer,
          first.length,
          secondPointer,
          second.length,
        ),
      ).value;
    } finally {
      calloc.free(firstPointer);
      calloc.free(secondPointer);
    }
  }

  Uint8List _bytesOne(_OneInputDart operation, Uint8List first) {
    final pointer = _copyInput(first);
    try {
      return _bytesResult(operation(_liveHandle, pointer, first.length));
    } finally {
      calloc.free(pointer);
    }
  }

  Uint8List _bytesTwo(
    _TwoInputDart operation,
    Uint8List first,
    Uint8List second,
  ) {
    final firstPointer = _copyInput(first);
    final secondPointer = _copyInput(second);
    try {
      return _bytesResult(
        operation(
          _liveHandle,
          firstPointer,
          first.length,
          secondPointer,
          second.length,
        ),
      );
    } finally {
      calloc.free(firstPointer);
      calloc.free(secondPointer);
    }
  }

  _NativeResult _takeResult(_NativeResult result) {
    if (result.code == 0) return result;
    throw MlsNativeException(_errorMessage(result.code));
  }

  Uint8List _bytesResult(_NativeResult result) {
    final checked = _takeResult(result);
    if (checked.buffer.data == nullptr || checked.buffer.length == 0) {
      return Uint8List(0);
    }
    try {
      return Uint8List.fromList(
        checked.buffer.data.asTypedList(checked.buffer.length),
      );
    } finally {
      _native.bufferFree(checked.buffer);
    }
  }

  static MlsPreparedCommit _preparedCommit(Uint8List bytes) {
    final cursor = _Cursor(bytes);
    final value = MlsPreparedCommit(
      parentEpoch: cursor.uint64(),
      acceptedEpoch: cursor.uint64(),
      commit: cursor.value(max: _maxWireBytes),
    );
    cursor.finish();
    return value;
  }

  static String _errorMessage(int code) => switch (code) {
    1 => 'The MLS bridge rejected invalid input.',
    2 => 'The requested MLS state does not exist.',
    3 => 'The MLS state conflicts with another pending operation.',
    4 => 'The MLS wire message is invalid.',
    5 => 'The MLS message has an unexpected type.',
    6 => 'The MLS cryptographic operation failed.',
    100 => 'The MLS bridge safely stopped an internal failure.',
    _ => 'The MLS bridge returned an unknown error.',
  };

  static Pointer<Uint8> _copyInput(Uint8List value) {
    if (value.isEmpty) {
      throw const MlsNativeException('MLS input cannot be empty.');
    }
    final pointer = calloc<Uint8>(value.length);
    pointer.asTypedList(value.length).setAll(0, value);
    return pointer;
  }
}
