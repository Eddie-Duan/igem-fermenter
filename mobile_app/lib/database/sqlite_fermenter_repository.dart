import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/fermentation_project.dart';
import '../models/sensor_reading.dart';
import 'fermenter_repository.dart';

class SqliteFermenterRepository implements FermenterRepository {
  SqliteFermenterRepository._(this._db);

  final Database _db;
  final _changes = StreamController<void>.broadcast();

  static Future<SqliteFermenterRepository> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final dbFactory = factory ?? databaseFactory;
    final dbPath =
        path ?? p.join(await dbFactory.getDatabasesPath(), 'fermenter.db');
    final db = await dbFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onConfigure: (db) async {
          await db.execute('PRAGMA synchronous = FULL');
        },
        onCreate: (db, version) async {
          await db.execute('''CREATE TABLE projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            strain TEXT,
            note TEXT,
            target_temp_c REAL NOT NULL,
            status INTEGER NOT NULL,
            time_scale INTEGER NOT NULL,
            sim_seconds INTEGER NOT NULL,
            stirrer_on INTEGER NOT NULL,
            stirrer_rpm INTEGER NOT NULL,
            heater_on INTEGER NOT NULL,
            peak_od REAL,
            harvest_at_seconds INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )''');
          await db.execute('''CREATE TABLE readings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id INTEGER NOT NULL,
            seq INTEGER NOT NULL,
            sim_seconds INTEGER NOT NULL,
            recorded_at INTEGER NOT NULL,
            temperature_c REAL NOT NULL,
            ph REAL NOT NULL,
            od REAL NOT NULL,
            note TEXT,
            source TEXT NOT NULL
          )''');
          await db.execute('CREATE INDEX readings_project_seq '
              'ON readings(project_id, seq)');
        },
      ),
    );
    return SqliteFermenterRepository._(db);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<int> createProject(FermentationProject project) async {
    final id = await _db.insert('projects', project.toMap()..remove('id'));
    _changes.add(null);
    return id;
  }

  @override
  Future<FermentationProject?> project(int id) async {
    final rows =
        await _db.query('projects', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return FermentationProject.fromMap(rows.single);
  }

  @override
  Future<List<FermentationProject>> listProjects() async =>
      (await _db.query('projects', orderBy: 'created_at DESC'))
          .map(FermentationProject.fromMap)
          .toList(growable: false);

  @override
  Future<void> updateProject(FermentationProject project) async {
    await _db
        .update('projects', project.toMap(), where: 'id = ?', whereArgs: [project.id]);
    _changes.add(null);
  }

  @override
  Future<void> deleteProject(int id) async {
    await _db.transaction((txn) async {
      await txn.delete('readings', where: 'project_id = ?', whereArgs: [id]);
      await txn.delete('projects', where: 'id = ?', whereArgs: [id]);
    });
    _changes.add(null);
  }

  @override
  Future<List<SensorReading>> readings(int projectId,
      {int limit = 0, bool ascending = false}) async {
    final rows = await _db.query('readings',
        where: 'project_id = ?',
        whereArgs: [projectId],
        orderBy: ascending ? 'seq ASC' : 'seq DESC',
        limit: limit == 0 ? null : limit);
    return rows.map(SensorReading.fromMap).toList(growable: false);
  }

  @override
  Future<int> addReading(SensorReading reading) async {
    final id = await _db.insert('readings', reading.toMap()..remove('id'));
    _changes.add(null);
    return id;
  }

  @override
  Future<int> countReadings(int projectId) async {
    final count = Sqflite.firstIntValue(await _db.rawQuery(
        'SELECT COUNT(*) FROM readings WHERE project_id = ?', [projectId]));
    return count ?? 0;
  }

  @override
  Future<void> deleteReadings(int projectId) async {
    await _db
        .delete('readings', where: 'project_id = ?', whereArgs: [projectId]);
    _changes.add(null);
  }

  @override
  Future<void> close() async {
    await _db.close();
    await _changes.close();
  }
}