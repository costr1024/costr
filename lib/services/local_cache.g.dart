// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_cache.dart';

// ignore_for_file: type=lint
class $EventsTable extends Events with TableInfo<$EventsTable, Event> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pubkeyMeta = const VerificationMeta('pubkey');
  @override
  late final GeneratedColumn<String> pubkey = GeneratedColumn<String>(
    'pubkey',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<int> kind = GeneratedColumn<int>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sigMeta = const VerificationMeta('sig');
  @override
  late final GeneratedColumn<String> sig = GeneratedColumn<String>(
    'sig',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
    'raw',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receivedAtMeta = const VerificationMeta(
    'receivedAt',
  );
  @override
  late final GeneratedColumn<int> receivedAt = GeneratedColumn<int>(
    'received_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    pubkey,
    kind,
    createdAt,
    content,
    sig,
    raw,
    tagsJson,
    receivedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'events';
  @override
  VerificationContext validateIntegrity(
    Insertable<Event> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('pubkey')) {
      context.handle(
        _pubkeyMeta,
        pubkey.isAcceptableOrUnknown(data['pubkey']!, _pubkeyMeta),
      );
    } else if (isInserting) {
      context.missing(_pubkeyMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('sig')) {
      context.handle(
        _sigMeta,
        sig.isAcceptableOrUnknown(data['sig']!, _sigMeta),
      );
    } else if (isInserting) {
      context.missing(_sigMeta);
    }
    if (data.containsKey('raw')) {
      context.handle(
        _rawMeta,
        raw.isAcceptableOrUnknown(data['raw']!, _rawMeta),
      );
    } else if (isInserting) {
      context.missing(_rawMeta);
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_tagsJsonMeta);
    }
    if (data.containsKey('received_at')) {
      context.handle(
        _receivedAtMeta,
        receivedAt.isAcceptableOrUnknown(data['received_at']!, _receivedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Event map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Event(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      pubkey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pubkey'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}kind'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      sig: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sig'],
      )!,
      raw: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}raw'],
      )!,
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
      receivedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}received_at'],
      )!,
    );
  }

  @override
  $EventsTable createAlias(String alias) {
    return $EventsTable(attachedDatabase, alias);
  }
}

class Event extends DataClass implements Insertable<Event> {
  final String id;
  final String pubkey;
  final int kind;
  final int createdAt;
  final String content;
  final String sig;
  final String raw;
  final String tagsJson;
  final int receivedAt;
  const Event({
    required this.id,
    required this.pubkey,
    required this.kind,
    required this.createdAt,
    required this.content,
    required this.sig,
    required this.raw,
    required this.tagsJson,
    required this.receivedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['pubkey'] = Variable<String>(pubkey);
    map['kind'] = Variable<int>(kind);
    map['created_at'] = Variable<int>(createdAt);
    map['content'] = Variable<String>(content);
    map['sig'] = Variable<String>(sig);
    map['raw'] = Variable<String>(raw);
    map['tags_json'] = Variable<String>(tagsJson);
    map['received_at'] = Variable<int>(receivedAt);
    return map;
  }

  EventsCompanion toCompanion(bool nullToAbsent) {
    return EventsCompanion(
      id: Value(id),
      pubkey: Value(pubkey),
      kind: Value(kind),
      createdAt: Value(createdAt),
      content: Value(content),
      sig: Value(sig),
      raw: Value(raw),
      tagsJson: Value(tagsJson),
      receivedAt: Value(receivedAt),
    );
  }

  factory Event.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Event(
      id: serializer.fromJson<String>(json['id']),
      pubkey: serializer.fromJson<String>(json['pubkey']),
      kind: serializer.fromJson<int>(json['kind']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      content: serializer.fromJson<String>(json['content']),
      sig: serializer.fromJson<String>(json['sig']),
      raw: serializer.fromJson<String>(json['raw']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
      receivedAt: serializer.fromJson<int>(json['receivedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'pubkey': serializer.toJson<String>(pubkey),
      'kind': serializer.toJson<int>(kind),
      'createdAt': serializer.toJson<int>(createdAt),
      'content': serializer.toJson<String>(content),
      'sig': serializer.toJson<String>(sig),
      'raw': serializer.toJson<String>(raw),
      'tagsJson': serializer.toJson<String>(tagsJson),
      'receivedAt': serializer.toJson<int>(receivedAt),
    };
  }

  Event copyWith({
    String? id,
    String? pubkey,
    int? kind,
    int? createdAt,
    String? content,
    String? sig,
    String? raw,
    String? tagsJson,
    int? receivedAt,
  }) => Event(
    id: id ?? this.id,
    pubkey: pubkey ?? this.pubkey,
    kind: kind ?? this.kind,
    createdAt: createdAt ?? this.createdAt,
    content: content ?? this.content,
    sig: sig ?? this.sig,
    raw: raw ?? this.raw,
    tagsJson: tagsJson ?? this.tagsJson,
    receivedAt: receivedAt ?? this.receivedAt,
  );
  Event copyWithCompanion(EventsCompanion data) {
    return Event(
      id: data.id.present ? data.id.value : this.id,
      pubkey: data.pubkey.present ? data.pubkey.value : this.pubkey,
      kind: data.kind.present ? data.kind.value : this.kind,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      content: data.content.present ? data.content.value : this.content,
      sig: data.sig.present ? data.sig.value : this.sig,
      raw: data.raw.present ? data.raw.value : this.raw,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      receivedAt: data.receivedAt.present
          ? data.receivedAt.value
          : this.receivedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Event(')
          ..write('id: $id, ')
          ..write('pubkey: $pubkey, ')
          ..write('kind: $kind, ')
          ..write('createdAt: $createdAt, ')
          ..write('content: $content, ')
          ..write('sig: $sig, ')
          ..write('raw: $raw, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('receivedAt: $receivedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    pubkey,
    kind,
    createdAt,
    content,
    sig,
    raw,
    tagsJson,
    receivedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Event &&
          other.id == this.id &&
          other.pubkey == this.pubkey &&
          other.kind == this.kind &&
          other.createdAt == this.createdAt &&
          other.content == this.content &&
          other.sig == this.sig &&
          other.raw == this.raw &&
          other.tagsJson == this.tagsJson &&
          other.receivedAt == this.receivedAt);
}

class EventsCompanion extends UpdateCompanion<Event> {
  final Value<String> id;
  final Value<String> pubkey;
  final Value<int> kind;
  final Value<int> createdAt;
  final Value<String> content;
  final Value<String> sig;
  final Value<String> raw;
  final Value<String> tagsJson;
  final Value<int> receivedAt;
  final Value<int> rowid;
  const EventsCompanion({
    this.id = const Value.absent(),
    this.pubkey = const Value.absent(),
    this.kind = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.content = const Value.absent(),
    this.sig = const Value.absent(),
    this.raw = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EventsCompanion.insert({
    required String id,
    required String pubkey,
    required int kind,
    required int createdAt,
    required String content,
    required String sig,
    required String raw,
    required String tagsJson,
    this.receivedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       pubkey = Value(pubkey),
       kind = Value(kind),
       createdAt = Value(createdAt),
       content = Value(content),
       sig = Value(sig),
       raw = Value(raw),
       tagsJson = Value(tagsJson);
  static Insertable<Event> custom({
    Expression<String>? id,
    Expression<String>? pubkey,
    Expression<int>? kind,
    Expression<int>? createdAt,
    Expression<String>? content,
    Expression<String>? sig,
    Expression<String>? raw,
    Expression<String>? tagsJson,
    Expression<int>? receivedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (pubkey != null) 'pubkey': pubkey,
      if (kind != null) 'kind': kind,
      if (createdAt != null) 'created_at': createdAt,
      if (content != null) 'content': content,
      if (sig != null) 'sig': sig,
      if (raw != null) 'raw': raw,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (receivedAt != null) 'received_at': receivedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EventsCompanion copyWith({
    Value<String>? id,
    Value<String>? pubkey,
    Value<int>? kind,
    Value<int>? createdAt,
    Value<String>? content,
    Value<String>? sig,
    Value<String>? raw,
    Value<String>? tagsJson,
    Value<int>? receivedAt,
    Value<int>? rowid,
  }) {
    return EventsCompanion(
      id: id ?? this.id,
      pubkey: pubkey ?? this.pubkey,
      kind: kind ?? this.kind,
      createdAt: createdAt ?? this.createdAt,
      content: content ?? this.content,
      sig: sig ?? this.sig,
      raw: raw ?? this.raw,
      tagsJson: tagsJson ?? this.tagsJson,
      receivedAt: receivedAt ?? this.receivedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (pubkey.present) {
      map['pubkey'] = Variable<String>(pubkey.value);
    }
    if (kind.present) {
      map['kind'] = Variable<int>(kind.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (sig.present) {
      map['sig'] = Variable<String>(sig.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (receivedAt.present) {
      map['received_at'] = Variable<int>(receivedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EventsCompanion(')
          ..write('id: $id, ')
          ..write('pubkey: $pubkey, ')
          ..write('kind: $kind, ')
          ..write('createdAt: $createdAt, ')
          ..write('content: $content, ')
          ..write('sig: $sig, ')
          ..write('raw: $raw, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReplaceableEventsTable extends ReplaceableEvents
    with TableInfo<$ReplaceableEventsTable, ReplaceableEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReplaceableEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _pubkeyMeta = const VerificationMeta('pubkey');
  @override
  late final GeneratedColumn<String> pubkey = GeneratedColumn<String>(
    'pubkey',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<int> kind = GeneratedColumn<int>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dTagMeta = const VerificationMeta('dTag');
  @override
  late final GeneratedColumn<String> dTag = GeneratedColumn<String>(
    'd_tag',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sigMeta = const VerificationMeta('sig');
  @override
  late final GeneratedColumn<String> sig = GeneratedColumn<String>(
    'sig',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
    'raw',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    pubkey,
    kind,
    dTag,
    id,
    createdAt,
    content,
    sig,
    raw,
    tagsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'replaceable_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReplaceableEvent> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('pubkey')) {
      context.handle(
        _pubkeyMeta,
        pubkey.isAcceptableOrUnknown(data['pubkey']!, _pubkeyMeta),
      );
    } else if (isInserting) {
      context.missing(_pubkeyMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('d_tag')) {
      context.handle(
        _dTagMeta,
        dTag.isAcceptableOrUnknown(data['d_tag']!, _dTagMeta),
      );
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('sig')) {
      context.handle(
        _sigMeta,
        sig.isAcceptableOrUnknown(data['sig']!, _sigMeta),
      );
    } else if (isInserting) {
      context.missing(_sigMeta);
    }
    if (data.containsKey('raw')) {
      context.handle(
        _rawMeta,
        raw.isAcceptableOrUnknown(data['raw']!, _rawMeta),
      );
    } else if (isInserting) {
      context.missing(_rawMeta);
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_tagsJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {pubkey, kind, dTag};
  @override
  ReplaceableEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReplaceableEvent(
      pubkey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pubkey'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}kind'],
      )!,
      dTag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}d_tag'],
      )!,
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      sig: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sig'],
      )!,
      raw: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}raw'],
      )!,
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
    );
  }

  @override
  $ReplaceableEventsTable createAlias(String alias) {
    return $ReplaceableEventsTable(attachedDatabase, alias);
  }
}

class ReplaceableEvent extends DataClass
    implements Insertable<ReplaceableEvent> {
  final String pubkey;
  final int kind;
  final String dTag;
  final String id;
  final int createdAt;
  final String content;
  final String sig;
  final String raw;
  final String tagsJson;
  const ReplaceableEvent({
    required this.pubkey,
    required this.kind,
    required this.dTag,
    required this.id,
    required this.createdAt,
    required this.content,
    required this.sig,
    required this.raw,
    required this.tagsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['pubkey'] = Variable<String>(pubkey);
    map['kind'] = Variable<int>(kind);
    map['d_tag'] = Variable<String>(dTag);
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['content'] = Variable<String>(content);
    map['sig'] = Variable<String>(sig);
    map['raw'] = Variable<String>(raw);
    map['tags_json'] = Variable<String>(tagsJson);
    return map;
  }

  ReplaceableEventsCompanion toCompanion(bool nullToAbsent) {
    return ReplaceableEventsCompanion(
      pubkey: Value(pubkey),
      kind: Value(kind),
      dTag: Value(dTag),
      id: Value(id),
      createdAt: Value(createdAt),
      content: Value(content),
      sig: Value(sig),
      raw: Value(raw),
      tagsJson: Value(tagsJson),
    );
  }

  factory ReplaceableEvent.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReplaceableEvent(
      pubkey: serializer.fromJson<String>(json['pubkey']),
      kind: serializer.fromJson<int>(json['kind']),
      dTag: serializer.fromJson<String>(json['dTag']),
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      content: serializer.fromJson<String>(json['content']),
      sig: serializer.fromJson<String>(json['sig']),
      raw: serializer.fromJson<String>(json['raw']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'pubkey': serializer.toJson<String>(pubkey),
      'kind': serializer.toJson<int>(kind),
      'dTag': serializer.toJson<String>(dTag),
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'content': serializer.toJson<String>(content),
      'sig': serializer.toJson<String>(sig),
      'raw': serializer.toJson<String>(raw),
      'tagsJson': serializer.toJson<String>(tagsJson),
    };
  }

  ReplaceableEvent copyWith({
    String? pubkey,
    int? kind,
    String? dTag,
    String? id,
    int? createdAt,
    String? content,
    String? sig,
    String? raw,
    String? tagsJson,
  }) => ReplaceableEvent(
    pubkey: pubkey ?? this.pubkey,
    kind: kind ?? this.kind,
    dTag: dTag ?? this.dTag,
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    content: content ?? this.content,
    sig: sig ?? this.sig,
    raw: raw ?? this.raw,
    tagsJson: tagsJson ?? this.tagsJson,
  );
  ReplaceableEvent copyWithCompanion(ReplaceableEventsCompanion data) {
    return ReplaceableEvent(
      pubkey: data.pubkey.present ? data.pubkey.value : this.pubkey,
      kind: data.kind.present ? data.kind.value : this.kind,
      dTag: data.dTag.present ? data.dTag.value : this.dTag,
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      content: data.content.present ? data.content.value : this.content,
      sig: data.sig.present ? data.sig.value : this.sig,
      raw: data.raw.present ? data.raw.value : this.raw,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReplaceableEvent(')
          ..write('pubkey: $pubkey, ')
          ..write('kind: $kind, ')
          ..write('dTag: $dTag, ')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('content: $content, ')
          ..write('sig: $sig, ')
          ..write('raw: $raw, ')
          ..write('tagsJson: $tagsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    pubkey,
    kind,
    dTag,
    id,
    createdAt,
    content,
    sig,
    raw,
    tagsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReplaceableEvent &&
          other.pubkey == this.pubkey &&
          other.kind == this.kind &&
          other.dTag == this.dTag &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.content == this.content &&
          other.sig == this.sig &&
          other.raw == this.raw &&
          other.tagsJson == this.tagsJson);
}

class ReplaceableEventsCompanion extends UpdateCompanion<ReplaceableEvent> {
  final Value<String> pubkey;
  final Value<int> kind;
  final Value<String> dTag;
  final Value<String> id;
  final Value<int> createdAt;
  final Value<String> content;
  final Value<String> sig;
  final Value<String> raw;
  final Value<String> tagsJson;
  final Value<int> rowid;
  const ReplaceableEventsCompanion({
    this.pubkey = const Value.absent(),
    this.kind = const Value.absent(),
    this.dTag = const Value.absent(),
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.content = const Value.absent(),
    this.sig = const Value.absent(),
    this.raw = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReplaceableEventsCompanion.insert({
    required String pubkey,
    required int kind,
    this.dTag = const Value.absent(),
    required String id,
    required int createdAt,
    required String content,
    required String sig,
    required String raw,
    required String tagsJson,
    this.rowid = const Value.absent(),
  }) : pubkey = Value(pubkey),
       kind = Value(kind),
       id = Value(id),
       createdAt = Value(createdAt),
       content = Value(content),
       sig = Value(sig),
       raw = Value(raw),
       tagsJson = Value(tagsJson);
  static Insertable<ReplaceableEvent> custom({
    Expression<String>? pubkey,
    Expression<int>? kind,
    Expression<String>? dTag,
    Expression<String>? id,
    Expression<int>? createdAt,
    Expression<String>? content,
    Expression<String>? sig,
    Expression<String>? raw,
    Expression<String>? tagsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (pubkey != null) 'pubkey': pubkey,
      if (kind != null) 'kind': kind,
      if (dTag != null) 'd_tag': dTag,
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (content != null) 'content': content,
      if (sig != null) 'sig': sig,
      if (raw != null) 'raw': raw,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReplaceableEventsCompanion copyWith({
    Value<String>? pubkey,
    Value<int>? kind,
    Value<String>? dTag,
    Value<String>? id,
    Value<int>? createdAt,
    Value<String>? content,
    Value<String>? sig,
    Value<String>? raw,
    Value<String>? tagsJson,
    Value<int>? rowid,
  }) {
    return ReplaceableEventsCompanion(
      pubkey: pubkey ?? this.pubkey,
      kind: kind ?? this.kind,
      dTag: dTag ?? this.dTag,
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      content: content ?? this.content,
      sig: sig ?? this.sig,
      raw: raw ?? this.raw,
      tagsJson: tagsJson ?? this.tagsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (pubkey.present) {
      map['pubkey'] = Variable<String>(pubkey.value);
    }
    if (kind.present) {
      map['kind'] = Variable<int>(kind.value);
    }
    if (dTag.present) {
      map['d_tag'] = Variable<String>(dTag.value);
    }
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (sig.present) {
      map['sig'] = Variable<String>(sig.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReplaceableEventsCompanion(')
          ..write('pubkey: $pubkey, ')
          ..write('kind: $kind, ')
          ..write('dTag: $dTag, ')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('content: $content, ')
          ..write('sig: $sig, ')
          ..write('raw: $raw, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $EventTagsTable extends EventTags
    with TableInfo<$EventTagsTable, EventTag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EventTagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _eventIdMeta = const VerificationMeta(
    'eventId',
  );
  @override
  late final GeneratedColumn<String> eventId = GeneratedColumn<String>(
    'event_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [eventId, name, value, position];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'event_tags';
  @override
  VerificationContext validateIntegrity(
    Insertable<EventTag> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('event_id')) {
      context.handle(
        _eventIdMeta,
        eventId.isAcceptableOrUnknown(data['event_id']!, _eventIdMeta),
      );
    } else if (isInserting) {
      context.missing(_eventIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {eventId, position};
  @override
  EventTag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EventTag(
      eventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
    );
  }

  @override
  $EventTagsTable createAlias(String alias) {
    return $EventTagsTable(attachedDatabase, alias);
  }
}

class EventTag extends DataClass implements Insertable<EventTag> {
  final String eventId;
  final String name;
  final String value;
  final int position;
  const EventTag({
    required this.eventId,
    required this.name,
    required this.value,
    required this.position,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['event_id'] = Variable<String>(eventId);
    map['name'] = Variable<String>(name);
    map['value'] = Variable<String>(value);
    map['position'] = Variable<int>(position);
    return map;
  }

  EventTagsCompanion toCompanion(bool nullToAbsent) {
    return EventTagsCompanion(
      eventId: Value(eventId),
      name: Value(name),
      value: Value(value),
      position: Value(position),
    );
  }

  factory EventTag.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EventTag(
      eventId: serializer.fromJson<String>(json['eventId']),
      name: serializer.fromJson<String>(json['name']),
      value: serializer.fromJson<String>(json['value']),
      position: serializer.fromJson<int>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'eventId': serializer.toJson<String>(eventId),
      'name': serializer.toJson<String>(name),
      'value': serializer.toJson<String>(value),
      'position': serializer.toJson<int>(position),
    };
  }

  EventTag copyWith({
    String? eventId,
    String? name,
    String? value,
    int? position,
  }) => EventTag(
    eventId: eventId ?? this.eventId,
    name: name ?? this.name,
    value: value ?? this.value,
    position: position ?? this.position,
  );
  EventTag copyWithCompanion(EventTagsCompanion data) {
    return EventTag(
      eventId: data.eventId.present ? data.eventId.value : this.eventId,
      name: data.name.present ? data.name.value : this.name,
      value: data.value.present ? data.value.value : this.value,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EventTag(')
          ..write('eventId: $eventId, ')
          ..write('name: $name, ')
          ..write('value: $value, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(eventId, name, value, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EventTag &&
          other.eventId == this.eventId &&
          other.name == this.name &&
          other.value == this.value &&
          other.position == this.position);
}

class EventTagsCompanion extends UpdateCompanion<EventTag> {
  final Value<String> eventId;
  final Value<String> name;
  final Value<String> value;
  final Value<int> position;
  final Value<int> rowid;
  const EventTagsCompanion({
    this.eventId = const Value.absent(),
    this.name = const Value.absent(),
    this.value = const Value.absent(),
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EventTagsCompanion.insert({
    required String eventId,
    required String name,
    required String value,
    required int position,
    this.rowid = const Value.absent(),
  }) : eventId = Value(eventId),
       name = Value(name),
       value = Value(value),
       position = Value(position);
  static Insertable<EventTag> custom({
    Expression<String>? eventId,
    Expression<String>? name,
    Expression<String>? value,
    Expression<int>? position,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (eventId != null) 'event_id': eventId,
      if (name != null) 'name': name,
      if (value != null) 'value': value,
      if (position != null) 'position': position,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EventTagsCompanion copyWith({
    Value<String>? eventId,
    Value<String>? name,
    Value<String>? value,
    Value<int>? position,
    Value<int>? rowid,
  }) {
    return EventTagsCompanion(
      eventId: eventId ?? this.eventId,
      name: name ?? this.name,
      value: value ?? this.value,
      position: position ?? this.position,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (eventId.present) {
      map['event_id'] = Variable<String>(eventId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EventTagsCompanion(')
          ..write('eventId: $eventId, ')
          ..write('name: $name, ')
          ..write('value: $value, ')
          ..write('position: $position, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConfigTableTable extends ConfigTable
    with TableInfo<$ConfigTableTable, ConfigTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConfigTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'config_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConfigTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  ConfigTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConfigTableData(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $ConfigTableTable createAlias(String alias) {
    return $ConfigTableTable(attachedDatabase, alias);
  }
}

class ConfigTableData extends DataClass implements Insertable<ConfigTableData> {
  final String key;
  final String value;
  const ConfigTableData({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  ConfigTableCompanion toCompanion(bool nullToAbsent) {
    return ConfigTableCompanion(key: Value(key), value: Value(value));
  }

  factory ConfigTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConfigTableData(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  ConfigTableData copyWith({String? key, String? value}) =>
      ConfigTableData(key: key ?? this.key, value: value ?? this.value);
  ConfigTableData copyWithCompanion(ConfigTableCompanion data) {
    return ConfigTableData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConfigTableData(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConfigTableData &&
          other.key == this.key &&
          other.value == this.value);
}

class ConfigTableCompanion extends UpdateCompanion<ConfigTableData> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const ConfigTableCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConfigTableCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<ConfigTableData> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConfigTableCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return ConfigTableCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConfigTableCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RelayConfigTable extends RelayConfig
    with TableInfo<$RelayConfigTable, RelayConfigData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RelayConfigTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<int> enabled = GeneratedColumn<int>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _readMeta = const VerificationMeta('read');
  @override
  late final GeneratedColumn<int> read = GeneratedColumn<int>(
    'read',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _writeMeta = const VerificationMeta('write');
  @override
  late final GeneratedColumn<int> write = GeneratedColumn<int>(
    'write',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [url, enabled, read, write, addedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'relay_config';
  @override
  VerificationContext validateIntegrity(
    Insertable<RelayConfigData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('read')) {
      context.handle(
        _readMeta,
        read.isAcceptableOrUnknown(data['read']!, _readMeta),
      );
    }
    if (data.containsKey('write')) {
      context.handle(
        _writeMeta,
        write.isAcceptableOrUnknown(data['write']!, _writeMeta),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {url};
  @override
  RelayConfigData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RelayConfigData(
      url: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}enabled'],
      )!,
      read: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}read'],
      )!,
      write: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}write'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
    );
  }

  @override
  $RelayConfigTable createAlias(String alias) {
    return $RelayConfigTable(attachedDatabase, alias);
  }
}

class RelayConfigData extends DataClass implements Insertable<RelayConfigData> {
  final String url;
  final int enabled;
  final int read;
  final int write;
  final int addedAt;
  const RelayConfigData({
    required this.url,
    required this.enabled,
    required this.read,
    required this.write,
    required this.addedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['url'] = Variable<String>(url);
    map['enabled'] = Variable<int>(enabled);
    map['read'] = Variable<int>(read);
    map['write'] = Variable<int>(write);
    map['added_at'] = Variable<int>(addedAt);
    return map;
  }

  RelayConfigCompanion toCompanion(bool nullToAbsent) {
    return RelayConfigCompanion(
      url: Value(url),
      enabled: Value(enabled),
      read: Value(read),
      write: Value(write),
      addedAt: Value(addedAt),
    );
  }

  factory RelayConfigData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RelayConfigData(
      url: serializer.fromJson<String>(json['url']),
      enabled: serializer.fromJson<int>(json['enabled']),
      read: serializer.fromJson<int>(json['read']),
      write: serializer.fromJson<int>(json['write']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'url': serializer.toJson<String>(url),
      'enabled': serializer.toJson<int>(enabled),
      'read': serializer.toJson<int>(read),
      'write': serializer.toJson<int>(write),
      'addedAt': serializer.toJson<int>(addedAt),
    };
  }

  RelayConfigData copyWith({
    String? url,
    int? enabled,
    int? read,
    int? write,
    int? addedAt,
  }) => RelayConfigData(
    url: url ?? this.url,
    enabled: enabled ?? this.enabled,
    read: read ?? this.read,
    write: write ?? this.write,
    addedAt: addedAt ?? this.addedAt,
  );
  RelayConfigData copyWithCompanion(RelayConfigCompanion data) {
    return RelayConfigData(
      url: data.url.present ? data.url.value : this.url,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      read: data.read.present ? data.read.value : this.read,
      write: data.write.present ? data.write.value : this.write,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RelayConfigData(')
          ..write('url: $url, ')
          ..write('enabled: $enabled, ')
          ..write('read: $read, ')
          ..write('write: $write, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(url, enabled, read, write, addedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RelayConfigData &&
          other.url == this.url &&
          other.enabled == this.enabled &&
          other.read == this.read &&
          other.write == this.write &&
          other.addedAt == this.addedAt);
}

class RelayConfigCompanion extends UpdateCompanion<RelayConfigData> {
  final Value<String> url;
  final Value<int> enabled;
  final Value<int> read;
  final Value<int> write;
  final Value<int> addedAt;
  final Value<int> rowid;
  const RelayConfigCompanion({
    this.url = const Value.absent(),
    this.enabled = const Value.absent(),
    this.read = const Value.absent(),
    this.write = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RelayConfigCompanion.insert({
    required String url,
    this.enabled = const Value.absent(),
    this.read = const Value.absent(),
    this.write = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : url = Value(url);
  static Insertable<RelayConfigData> custom({
    Expression<String>? url,
    Expression<int>? enabled,
    Expression<int>? read,
    Expression<int>? write,
    Expression<int>? addedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (url != null) 'url': url,
      if (enabled != null) 'enabled': enabled,
      if (read != null) 'read': read,
      if (write != null) 'write': write,
      if (addedAt != null) 'added_at': addedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RelayConfigCompanion copyWith({
    Value<String>? url,
    Value<int>? enabled,
    Value<int>? read,
    Value<int>? write,
    Value<int>? addedAt,
    Value<int>? rowid,
  }) {
    return RelayConfigCompanion(
      url: url ?? this.url,
      enabled: enabled ?? this.enabled,
      read: read ?? this.read,
      write: write ?? this.write,
      addedAt: addedAt ?? this.addedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<int>(enabled.value);
    }
    if (read.present) {
      map['read'] = Variable<int>(read.value);
    }
    if (write.present) {
      map['write'] = Variable<int>(write.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RelayConfigCompanion(')
          ..write('url: $url, ')
          ..write('enabled: $enabled, ')
          ..write('read: $read, ')
          ..write('write: $write, ')
          ..write('addedAt: $addedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LocalCache extends GeneratedDatabase {
  _$LocalCache(QueryExecutor e) : super(e);
  $LocalCacheManager get managers => $LocalCacheManager(this);
  late final $EventsTable events = $EventsTable(this);
  late final $ReplaceableEventsTable replaceableEvents =
      $ReplaceableEventsTable(this);
  late final $EventTagsTable eventTags = $EventTagsTable(this);
  late final $ConfigTableTable configTable = $ConfigTableTable(this);
  late final $RelayConfigTable relayConfig = $RelayConfigTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    events,
    replaceableEvents,
    eventTags,
    configTable,
    relayConfig,
  ];
}

typedef $$EventsTableCreateCompanionBuilder =
    EventsCompanion Function({
      required String id,
      required String pubkey,
      required int kind,
      required int createdAt,
      required String content,
      required String sig,
      required String raw,
      required String tagsJson,
      Value<int> receivedAt,
      Value<int> rowid,
    });
typedef $$EventsTableUpdateCompanionBuilder =
    EventsCompanion Function({
      Value<String> id,
      Value<String> pubkey,
      Value<int> kind,
      Value<int> createdAt,
      Value<String> content,
      Value<String> sig,
      Value<String> raw,
      Value<String> tagsJson,
      Value<int> receivedAt,
      Value<int> rowid,
    });

class $$EventsTableFilterComposer extends Composer<_$LocalCache, $EventsTable> {
  $$EventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pubkey => $composableBuilder(
    column: $table.pubkey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sig => $composableBuilder(
    column: $table.sig,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EventsTableOrderingComposer
    extends Composer<_$LocalCache, $EventsTable> {
  $$EventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pubkey => $composableBuilder(
    column: $table.pubkey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sig => $composableBuilder(
    column: $table.sig,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EventsTableAnnotationComposer
    extends Composer<_$LocalCache, $EventsTable> {
  $$EventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get pubkey =>
      $composableBuilder(column: $table.pubkey, builder: (column) => column);

  GeneratedColumn<int> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get sig =>
      $composableBuilder(column: $table.sig, builder: (column) => column);

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => column,
  );
}

class $$EventsTableTableManager
    extends
        RootTableManager<
          _$LocalCache,
          $EventsTable,
          Event,
          $$EventsTableFilterComposer,
          $$EventsTableOrderingComposer,
          $$EventsTableAnnotationComposer,
          $$EventsTableCreateCompanionBuilder,
          $$EventsTableUpdateCompanionBuilder,
          (Event, BaseReferences<_$LocalCache, $EventsTable, Event>),
          Event,
          PrefetchHooks Function()
        > {
  $$EventsTableTableManager(_$LocalCache db, $EventsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> pubkey = const Value.absent(),
                Value<int> kind = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String> sig = const Value.absent(),
                Value<String> raw = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<int> receivedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EventsCompanion(
                id: id,
                pubkey: pubkey,
                kind: kind,
                createdAt: createdAt,
                content: content,
                sig: sig,
                raw: raw,
                tagsJson: tagsJson,
                receivedAt: receivedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String pubkey,
                required int kind,
                required int createdAt,
                required String content,
                required String sig,
                required String raw,
                required String tagsJson,
                Value<int> receivedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EventsCompanion.insert(
                id: id,
                pubkey: pubkey,
                kind: kind,
                createdAt: createdAt,
                content: content,
                sig: sig,
                raw: raw,
                tagsJson: tagsJson,
                receivedAt: receivedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EventsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalCache,
      $EventsTable,
      Event,
      $$EventsTableFilterComposer,
      $$EventsTableOrderingComposer,
      $$EventsTableAnnotationComposer,
      $$EventsTableCreateCompanionBuilder,
      $$EventsTableUpdateCompanionBuilder,
      (Event, BaseReferences<_$LocalCache, $EventsTable, Event>),
      Event,
      PrefetchHooks Function()
    >;
typedef $$ReplaceableEventsTableCreateCompanionBuilder =
    ReplaceableEventsCompanion Function({
      required String pubkey,
      required int kind,
      Value<String> dTag,
      required String id,
      required int createdAt,
      required String content,
      required String sig,
      required String raw,
      required String tagsJson,
      Value<int> rowid,
    });
typedef $$ReplaceableEventsTableUpdateCompanionBuilder =
    ReplaceableEventsCompanion Function({
      Value<String> pubkey,
      Value<int> kind,
      Value<String> dTag,
      Value<String> id,
      Value<int> createdAt,
      Value<String> content,
      Value<String> sig,
      Value<String> raw,
      Value<String> tagsJson,
      Value<int> rowid,
    });

class $$ReplaceableEventsTableFilterComposer
    extends Composer<_$LocalCache, $ReplaceableEventsTable> {
  $$ReplaceableEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get pubkey => $composableBuilder(
    column: $table.pubkey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dTag => $composableBuilder(
    column: $table.dTag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sig => $composableBuilder(
    column: $table.sig,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReplaceableEventsTableOrderingComposer
    extends Composer<_$LocalCache, $ReplaceableEventsTable> {
  $$ReplaceableEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get pubkey => $composableBuilder(
    column: $table.pubkey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dTag => $composableBuilder(
    column: $table.dTag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sig => $composableBuilder(
    column: $table.sig,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReplaceableEventsTableAnnotationComposer
    extends Composer<_$LocalCache, $ReplaceableEventsTable> {
  $$ReplaceableEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get pubkey =>
      $composableBuilder(column: $table.pubkey, builder: (column) => column);

  GeneratedColumn<int> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get dTag =>
      $composableBuilder(column: $table.dTag, builder: (column) => column);

  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get sig =>
      $composableBuilder(column: $table.sig, builder: (column) => column);

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);
}

class $$ReplaceableEventsTableTableManager
    extends
        RootTableManager<
          _$LocalCache,
          $ReplaceableEventsTable,
          ReplaceableEvent,
          $$ReplaceableEventsTableFilterComposer,
          $$ReplaceableEventsTableOrderingComposer,
          $$ReplaceableEventsTableAnnotationComposer,
          $$ReplaceableEventsTableCreateCompanionBuilder,
          $$ReplaceableEventsTableUpdateCompanionBuilder,
          (
            ReplaceableEvent,
            BaseReferences<
              _$LocalCache,
              $ReplaceableEventsTable,
              ReplaceableEvent
            >,
          ),
          ReplaceableEvent,
          PrefetchHooks Function()
        > {
  $$ReplaceableEventsTableTableManager(
    _$LocalCache db,
    $ReplaceableEventsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReplaceableEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReplaceableEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReplaceableEventsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> pubkey = const Value.absent(),
                Value<int> kind = const Value.absent(),
                Value<String> dTag = const Value.absent(),
                Value<String> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String> sig = const Value.absent(),
                Value<String> raw = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReplaceableEventsCompanion(
                pubkey: pubkey,
                kind: kind,
                dTag: dTag,
                id: id,
                createdAt: createdAt,
                content: content,
                sig: sig,
                raw: raw,
                tagsJson: tagsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String pubkey,
                required int kind,
                Value<String> dTag = const Value.absent(),
                required String id,
                required int createdAt,
                required String content,
                required String sig,
                required String raw,
                required String tagsJson,
                Value<int> rowid = const Value.absent(),
              }) => ReplaceableEventsCompanion.insert(
                pubkey: pubkey,
                kind: kind,
                dTag: dTag,
                id: id,
                createdAt: createdAt,
                content: content,
                sig: sig,
                raw: raw,
                tagsJson: tagsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReplaceableEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalCache,
      $ReplaceableEventsTable,
      ReplaceableEvent,
      $$ReplaceableEventsTableFilterComposer,
      $$ReplaceableEventsTableOrderingComposer,
      $$ReplaceableEventsTableAnnotationComposer,
      $$ReplaceableEventsTableCreateCompanionBuilder,
      $$ReplaceableEventsTableUpdateCompanionBuilder,
      (
        ReplaceableEvent,
        BaseReferences<_$LocalCache, $ReplaceableEventsTable, ReplaceableEvent>,
      ),
      ReplaceableEvent,
      PrefetchHooks Function()
    >;
typedef $$EventTagsTableCreateCompanionBuilder =
    EventTagsCompanion Function({
      required String eventId,
      required String name,
      required String value,
      required int position,
      Value<int> rowid,
    });
typedef $$EventTagsTableUpdateCompanionBuilder =
    EventTagsCompanion Function({
      Value<String> eventId,
      Value<String> name,
      Value<String> value,
      Value<int> position,
      Value<int> rowid,
    });

class $$EventTagsTableFilterComposer
    extends Composer<_$LocalCache, $EventTagsTable> {
  $$EventTagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EventTagsTableOrderingComposer
    extends Composer<_$LocalCache, $EventTagsTable> {
  $$EventTagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EventTagsTableAnnotationComposer
    extends Composer<_$LocalCache, $EventTagsTable> {
  $$EventTagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get eventId =>
      $composableBuilder(column: $table.eventId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);
}

class $$EventTagsTableTableManager
    extends
        RootTableManager<
          _$LocalCache,
          $EventTagsTable,
          EventTag,
          $$EventTagsTableFilterComposer,
          $$EventTagsTableOrderingComposer,
          $$EventTagsTableAnnotationComposer,
          $$EventTagsTableCreateCompanionBuilder,
          $$EventTagsTableUpdateCompanionBuilder,
          (EventTag, BaseReferences<_$LocalCache, $EventTagsTable, EventTag>),
          EventTag,
          PrefetchHooks Function()
        > {
  $$EventTagsTableTableManager(_$LocalCache db, $EventTagsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EventTagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EventTagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EventTagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> eventId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EventTagsCompanion(
                eventId: eventId,
                name: name,
                value: value,
                position: position,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String eventId,
                required String name,
                required String value,
                required int position,
                Value<int> rowid = const Value.absent(),
              }) => EventTagsCompanion.insert(
                eventId: eventId,
                name: name,
                value: value,
                position: position,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EventTagsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalCache,
      $EventTagsTable,
      EventTag,
      $$EventTagsTableFilterComposer,
      $$EventTagsTableOrderingComposer,
      $$EventTagsTableAnnotationComposer,
      $$EventTagsTableCreateCompanionBuilder,
      $$EventTagsTableUpdateCompanionBuilder,
      (EventTag, BaseReferences<_$LocalCache, $EventTagsTable, EventTag>),
      EventTag,
      PrefetchHooks Function()
    >;
typedef $$ConfigTableTableCreateCompanionBuilder =
    ConfigTableCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$ConfigTableTableUpdateCompanionBuilder =
    ConfigTableCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$ConfigTableTableFilterComposer
    extends Composer<_$LocalCache, $ConfigTableTable> {
  $$ConfigTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConfigTableTableOrderingComposer
    extends Composer<_$LocalCache, $ConfigTableTable> {
  $$ConfigTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConfigTableTableAnnotationComposer
    extends Composer<_$LocalCache, $ConfigTableTable> {
  $$ConfigTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$ConfigTableTableTableManager
    extends
        RootTableManager<
          _$LocalCache,
          $ConfigTableTable,
          ConfigTableData,
          $$ConfigTableTableFilterComposer,
          $$ConfigTableTableOrderingComposer,
          $$ConfigTableTableAnnotationComposer,
          $$ConfigTableTableCreateCompanionBuilder,
          $$ConfigTableTableUpdateCompanionBuilder,
          (
            ConfigTableData,
            BaseReferences<_$LocalCache, $ConfigTableTable, ConfigTableData>,
          ),
          ConfigTableData,
          PrefetchHooks Function()
        > {
  $$ConfigTableTableTableManager(_$LocalCache db, $ConfigTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConfigTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConfigTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConfigTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConfigTableCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => ConfigTableCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConfigTableTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalCache,
      $ConfigTableTable,
      ConfigTableData,
      $$ConfigTableTableFilterComposer,
      $$ConfigTableTableOrderingComposer,
      $$ConfigTableTableAnnotationComposer,
      $$ConfigTableTableCreateCompanionBuilder,
      $$ConfigTableTableUpdateCompanionBuilder,
      (
        ConfigTableData,
        BaseReferences<_$LocalCache, $ConfigTableTable, ConfigTableData>,
      ),
      ConfigTableData,
      PrefetchHooks Function()
    >;
typedef $$RelayConfigTableCreateCompanionBuilder =
    RelayConfigCompanion Function({
      required String url,
      Value<int> enabled,
      Value<int> read,
      Value<int> write,
      Value<int> addedAt,
      Value<int> rowid,
    });
typedef $$RelayConfigTableUpdateCompanionBuilder =
    RelayConfigCompanion Function({
      Value<String> url,
      Value<int> enabled,
      Value<int> read,
      Value<int> write,
      Value<int> addedAt,
      Value<int> rowid,
    });

class $$RelayConfigTableFilterComposer
    extends Composer<_$LocalCache, $RelayConfigTable> {
  $$RelayConfigTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get read => $composableBuilder(
    column: $table.read,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get write => $composableBuilder(
    column: $table.write,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RelayConfigTableOrderingComposer
    extends Composer<_$LocalCache, $RelayConfigTable> {
  $$RelayConfigTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get read => $composableBuilder(
    column: $table.read,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get write => $composableBuilder(
    column: $table.write,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RelayConfigTableAnnotationComposer
    extends Composer<_$LocalCache, $RelayConfigTable> {
  $$RelayConfigTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<int> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<int> get read =>
      $composableBuilder(column: $table.read, builder: (column) => column);

  GeneratedColumn<int> get write =>
      $composableBuilder(column: $table.write, builder: (column) => column);

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);
}

class $$RelayConfigTableTableManager
    extends
        RootTableManager<
          _$LocalCache,
          $RelayConfigTable,
          RelayConfigData,
          $$RelayConfigTableFilterComposer,
          $$RelayConfigTableOrderingComposer,
          $$RelayConfigTableAnnotationComposer,
          $$RelayConfigTableCreateCompanionBuilder,
          $$RelayConfigTableUpdateCompanionBuilder,
          (
            RelayConfigData,
            BaseReferences<_$LocalCache, $RelayConfigTable, RelayConfigData>,
          ),
          RelayConfigData,
          PrefetchHooks Function()
        > {
  $$RelayConfigTableTableManager(_$LocalCache db, $RelayConfigTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RelayConfigTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RelayConfigTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RelayConfigTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> url = const Value.absent(),
                Value<int> enabled = const Value.absent(),
                Value<int> read = const Value.absent(),
                Value<int> write = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RelayConfigCompanion(
                url: url,
                enabled: enabled,
                read: read,
                write: write,
                addedAt: addedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String url,
                Value<int> enabled = const Value.absent(),
                Value<int> read = const Value.absent(),
                Value<int> write = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RelayConfigCompanion.insert(
                url: url,
                enabled: enabled,
                read: read,
                write: write,
                addedAt: addedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RelayConfigTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalCache,
      $RelayConfigTable,
      RelayConfigData,
      $$RelayConfigTableFilterComposer,
      $$RelayConfigTableOrderingComposer,
      $$RelayConfigTableAnnotationComposer,
      $$RelayConfigTableCreateCompanionBuilder,
      $$RelayConfigTableUpdateCompanionBuilder,
      (
        RelayConfigData,
        BaseReferences<_$LocalCache, $RelayConfigTable, RelayConfigData>,
      ),
      RelayConfigData,
      PrefetchHooks Function()
    >;

class $LocalCacheManager {
  final _$LocalCache _db;
  $LocalCacheManager(this._db);
  $$EventsTableTableManager get events =>
      $$EventsTableTableManager(_db, _db.events);
  $$ReplaceableEventsTableTableManager get replaceableEvents =>
      $$ReplaceableEventsTableTableManager(_db, _db.replaceableEvents);
  $$EventTagsTableTableManager get eventTags =>
      $$EventTagsTableTableManager(_db, _db.eventTags);
  $$ConfigTableTableTableManager get configTable =>
      $$ConfigTableTableTableManager(_db, _db.configTable);
  $$RelayConfigTableTableManager get relayConfig =>
      $$RelayConfigTableTableManager(_db, _db.relayConfig);
}
