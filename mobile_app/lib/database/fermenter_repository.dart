import '../models/fermentation_project.dart';
import '../models/sensor_reading.dart';

/// 未来的硬件接口就挂在同一个仓库上：设备控制器只往这里写读数，
/// 手动录入走同一条路径。
abstract class FermenterRepository {
  /// 数据变更信号（写库成功后广播），供页面自动刷新。
  Stream<void> get changes;

  Future<int> createProject(FermentationProject project);
  Future<FermentationProject?> project(int id);
  Future<List<FermentationProject>> listProjects();
  Future<void> updateProject(FermentationProject project);
  Future<void> deleteProject(int id);

  Future<List<SensorReading>> readings(int projectId,
      {int limit = 0, bool ascending = false});
  Future<int> addReading(SensorReading reading);
  Future<int> countReadings(int projectId);
  Future<void> deleteReadings(int projectId);
  Future<void> close();
}

/// 新建批次用的草稿，由页面表单构造，Controller 负责落库并启动仿真。
class ProjectDraft {
  const ProjectDraft({
    required this.name,
    required this.strain,
    required this.note,
    required this.targetTempC,
    required this.timeScale,
  });

  final String name;
  final String? strain;
  final String? note;
  final double targetTempC;
  final int timeScale;
}