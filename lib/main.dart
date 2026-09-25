import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tz;

// ═══════════════════════════════════════════════════════════════════════════
//  NOTIFICATION SERVICE
// ═══════════════════════════════════════════════════════════════════════════

final FlutterLocalNotificationsPlugin _notif = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
void _onBackgroundTap(NotificationResponse r) {
  debugPrint('[Notif] Background tap: ${r.payload}');
}

Future<void> initNotifications() async {
  tz.initializeTimeZones();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwinInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  await _notif.initialize(
    const InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
    ),
    onDidReceiveNotificationResponse: (r) =>
        debugPrint('[Notif] Foreground tap: ${r.payload}'),
    onDidReceiveBackgroundNotificationResponse: _onBackgroundTap,
  );
  final android = _notif.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (android != null) {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'doit_reminders_channel',
      'DoIt Reminders',
      description: 'DoIt task and note reminders with sound',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
    );
    await android.createNotificationChannel(channel);

    final prefs = await SharedPreferences.getInstance();
    final bool alreadyAsked = prefs.getBool('notif_permission_requested') ?? false;

    if (!alreadyAsked) {
      await android.requestNotificationsPermission();
      await android.requestExactAlarmsPermission();
      await prefs.setBool('notif_permission_requested', true);
    }
  }
}

Future<void> scheduleNotif({
  required int id,
  required String title,
  required String body,
  required DateTime at,
  GoalType? repeatType,
  RecurrenceType? recurrenceType,
}) async {
  try {
    RecurrenceType finalRecurrence;
    if (recurrenceType != null) {
      finalRecurrence = recurrenceType;
    } else if (repeatType != null) {
      switch (repeatType) {
        case GoalType.daily:   finalRecurrence = RecurrenceType.daily; break;
        case GoalType.weekly:  finalRecurrence = RecurrenceType.weekly; break;
        case GoalType.monthly: finalRecurrence = RecurrenceType.monthly; break;
      }
    } else {
      finalRecurrence = RecurrenceType.daily;
    }

    DateTime scheduledAt = at;
    final now = DateTime.now();

    // If the scheduled time is in the past, advance to the next upcoming occurrence
    if (scheduledAt.isBefore(now)) {
      switch (finalRecurrence) {
        case RecurrenceType.daily:
          while (scheduledAt.isBefore(now)) {
            scheduledAt = scheduledAt.add(const Duration(days: 1));
          }
          break;
        case RecurrenceType.weekly:
          while (scheduledAt.isBefore(now)) {
            scheduledAt = scheduledAt.add(const Duration(days: 7));
          }
          break;
        case RecurrenceType.monthly:
          while (scheduledAt.isBefore(now)) {
            var nextMonth = scheduledAt.month + 1;
            var nextYear = scheduledAt.year;
            if (nextMonth > 12) {
              nextMonth = 1;
              nextYear += 1;
            }
            final lastDayInNextMonth = DateTime(nextYear, nextMonth + 1, 0).day;
            final day = min(scheduledAt.day, lastDayInNextMonth);
            scheduledAt = DateTime(nextYear, nextMonth, day, scheduledAt.hour, scheduledAt.minute);
          }
          break;
        case RecurrenceType.none:
          if (scheduledAt.isBefore(now)) return;
          break;
      }
    }

    DateTimeComponents? matchComponents;
    switch (finalRecurrence) {
      case RecurrenceType.daily:
        matchComponents = DateTimeComponents.time;
        break;
      case RecurrenceType.weekly:
        matchComponents = DateTimeComponents.dayOfWeekAndTime;
        break;
      case RecurrenceType.monthly:
        matchComponents = DateTimeComponents.dayOfMonthAndTime;
        break;
      case RecurrenceType.none:
        matchComponents = null;
        break;
    }

    await _notif.zonedSchedule(
      id, title, body,
      tz.TZDateTime.from(scheduledAt, tz.local),
      NotificationDetails(
        android: AndroidNotificationDetails(
          'doit_reminders_channel',
          'DoIt Reminders',
          channelDescription: 'DoIt task and note reminders with sound',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          visibility: NotificationVisibility.public,
          styleInformation: BigTextStyleInformation(body),
        ),
        iOS: const DarwinNotificationDetails(
          presentSound: true,
          presentAlert: true,
          presentBadge: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
      UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: matchComponents,
      payload: '$id',
    );
  } catch (e) {
    debugPrint('[Notif] FAILED: $e');
  }
}

Future<void> showInstantNotif(String title, String body) async {
  SystemSound.play(SystemSoundType.alert);
  await _notif.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title, body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'doit_reminders_channel',
        'DoIt Reminders',
        channelDescription: 'DoIt task and note reminders with sound',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        visibility: NotificationVisibility.public,
      ),
      iOS: DarwinNotificationDetails(
        presentSound: true,
        presentAlert: true,
        presentBadge: true,
      ),
    ),
  );
}

Future<void> cancelNotif(int id) async => _notif.cancel(id);

Future<void> rescheduleAllNotifications() async {
  for (final t in taskStore.value) {
    if (t.reminderTime != null) {
      if (t.isStopped || t.done) {
        await cancelNotif(t.id.hashCode);
      } else {
        await scheduleNotif(
          id: t.id.hashCode,
          title: t.text,
          body: "Task Reminder • ${t.recurrenceType.label}",
          at: t.reminderTime!,
          repeatType: t.goalType,
        );
      }
    }
  }

  for (final n in noteStore.value) {
    if (n.reminderTime != null) {
      if (n.isCompleted) {
        await cancelNotif(n.id.hashCode);
      } else {
        await scheduleNotif(
          id: n.id.hashCode,
          title: n.title.isEmpty ? 'Note Reminder' : n.title,
          body: n.type == 'checklist' ? 'Checklist Reminder' : 'Note Reminder',
          at: n.reminderTime!,
          recurrenceType: RecurrenceType.none,
        );
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  APP-WIDE STATE  (ValueNotifier — unified store)
// ═══════════════════════════════════════════════════════════════════════════

class _TaskStore extends ValueNotifier<List<AppTask>> {
  _TaskStore() : super([]);
  int points = 0;

  Future<void> load() async {
    final tasks = await Storage.loadTasks();
    final pts   = await Storage.getPoints();
    points = pts;
    value  = tasks;
  }

  Future<void> toggle(String taskId) async {
    final idx = value.indexWhere((t) => t.id == taskId);
    if (idx == -1) return;

    final old = value[idx];
    if (old.isRecurring) {
      await toggleToday(taskId);
      return;
    }

    final updated = old.done
        ? old.copyWith(done: false, clearCompleted: true)
        : old.copyWith(done: true,  completedAt: DateTime.now());

    points += old.done ? -old.points : old.points;
    if (points < 0) points = 0;

    final newList = List<AppTask>.from(value);
    newList[idx] = updated;
    value = newList;

    Storage.saveTasks(newList);
    Storage.savePoints(points);
  }

  Future<void> toggleToday(String taskId) async {
    final idx = value.indexWhere((t) => t.id == taskId);
    if (idx == -1) return;

    final old = value[idx];
    final todayKey = AppTask.formatDateKey(DateTime.now());
    final isDoneToday = old.completedDates.contains(todayKey);

    final newDates = List<String>.from(old.completedDates);
    if (isDoneToday) {
      newDates.remove(todayKey);
      points -= old.points;
      if (points < 0) points = 0;
    } else {
      newDates.add(todayKey);
      points += old.points;
    }

    final updated = old.copyWith(completedDates: newDates);
    final newList = List<AppTask>.from(value);
    newList[idx] = updated;
    value = newList;

    await Storage.saveTasks(newList);
    await Storage.savePoints(points);
  }

  Future<void> stopRecurringTask(String taskId) async {
    final idx = value.indexWhere((t) => t.id == taskId);
    if (idx == -1) return;

    final old = value[idx];
    final updated = old.copyWith(isStopped: true);
    final newList = List<AppTask>.from(value);
    newList[idx] = updated;
    value = newList;

    await cancelNotif(old.id.hashCode);
    await Storage.saveTasks(newList);
  }

  Future<void> replace(AppTask updated) async {
    final idx = value.indexWhere((t) => t.id == updated.id);
    if (idx == -1) return;
    final newList = List<AppTask>.from(value);
    newList[idx] = updated;
    value = newList;
    await Storage.saveTasks(newList);
  }

  Future<void> add(AppTask t) async {
    final newList = List<AppTask>.from(value)..add(t);
    value = newList;
    await Storage.saveTasks(newList);
  }

  Future<void> addMultiple(List<AppTask> tasks) async {
    final newList = List<AppTask>.from(value)..addAll(tasks);
    value = newList;
    await Storage.saveTasks(newList);
  }

  Future<void> remove(String taskId) async {
    final idx = value.indexWhere((t) => t.id == taskId);
    if (idx != -1) {
      final task = value[idx];
      if (task.done || task.isCompletedToday) {
        points -= task.points;
        if (points < 0) points = 0;
        await Storage.savePoints(points);
      }
    }
    final newList = value.where((t) => t.id != taskId).toList();
    value = newList;
    await Storage.saveTasks(newList);
  }
}

final taskStore = _TaskStore();

// ═══════════════════════════════════════════════════════════════════════════
//  NOTE STORE (Unified notes + checklists)
// ═══════════════════════════════════════════════════════════════════════════

class _NoteStore extends ValueNotifier<List<Note>> {
  _NoteStore() : super([]);

  Future<void> load() async {
    final notes = await Storage.loadNotes();
    value = notes;
  }

  Future<void> create(Note n) async {
    final newList = List<Note>.from(value)..insert(0, n);
    value = newList;
    await Storage.saveNotes(newList);
    taskStore.points += 10;
    await Storage.savePoints(taskStore.points);
    taskStore.notifyListeners();
  }

  Future<void> update(Note updated) async {
    final idx = value.indexWhere((n) => n.id == updated.id);
    if (idx == -1) return;
    final newList = List<Note>.from(value);
    newList[idx] = updated;
    value = newList;
    await Storage.saveNotes(newList);
  }

  Future<void> delete(String noteId) async {
    final note = getNote(noteId);
    if (note != null) {
      taskStore.points -= 10;
      if (note.type == 'checklist') {
        final completedCount = note.checklistItems.where((i) => i.isComplete).length;
        taskStore.points -= completedCount * 10;
      }
      if (taskStore.points < 0) taskStore.points = 0;
      await Storage.savePoints(taskStore.points);
      taskStore.notifyListeners();
    }
    final newList = value.where((n) => n.id != noteId).toList();
    value = newList;
    await Storage.saveNotes(newList);
  }

  Note? getNote(String id) {
    try {
      return value.firstWhere((n) => n.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Toggle a checklist item's completion status
  Future<void> toggleChecklistItem(String noteId, int itemIndex) async {
    final note = getNote(noteId);
    if (note == null || note.type != 'checklist' || itemIndex >= note.checklistItems.length) return;

    final items = List<ChecklistItem>.from(note.checklistItems);
    final wasComplete = items[itemIndex].isComplete;
    items[itemIndex] = items[itemIndex].copyWith(
      isComplete: !wasComplete,
    );

    final ptsChange = wasComplete ? -10 : 10;
    taskStore.points += ptsChange;
    if (taskStore.points < 0) taskStore.points = 0;
    await Storage.savePoints(taskStore.points);
    taskStore.notifyListeners();

    await update(note.copyWith(checklistItems: items));
  }
}

final noteStore = _NoteStore();

// ═══════════════════════════════════════════════════════════════════════════
//  MODELS
// ═══════════════════════════════════════════════════════════════════════════

enum GoalType { daily, weekly, monthly }

extension GoalTypeX on GoalType {
  String   get label => ['Daily', 'Weekly', 'Monthly'][index];
  Color    get color => [const Color(0xFF6C63FF),
    const Color(0xFF0EA5E9),
    const Color(0xFFF59E0B)][index];
  IconData get icon  => [Icons.today_rounded,
    Icons.view_week_rounded,
    Icons.calendar_month_rounded][index];
}

enum RecurrenceType { none, daily, weekly, monthly }

extension RecurrenceTypeX on RecurrenceType {
  String get label => ['Does not repeat', 'Daily', 'Weekly', 'Monthly'][index];
}

class AppTask {
  final String  id;
  final String  text;
  final bool    done;
  final DateTime? reminderTime;
  final GoalType  goalType;
  final String    category;
  final int       points;
  final DateTime  createdAt;
  final DateTime? completedAt;
  final RecurrenceType recurrenceType;
  final List<int> weeklyDays; // 1=Mon, ..., 7=Sun
  final int? monthlyDay; // 1-31
  final List<String> completedDates; // ["YYYY-MM-DD", ...]
  final bool isStopped;

  const AppTask._({
    required this.id,
    required this.text,
    required this.done,
    required this.reminderTime,
    required this.goalType,
    required this.category,
    required this.points,
    required this.createdAt,
    required this.completedAt,
    required this.recurrenceType,
    required this.weeklyDays,
    required this.monthlyDay,
    required this.completedDates,
    required this.isStopped,
  });

  factory AppTask({
    String? id,
    required String text,
    bool done = false,
    DateTime? reminderTime,
    GoalType goalType = GoalType.daily,
    String category = 'general',
    int points = 10,
    DateTime? createdAt,
    DateTime? completedAt,
    RecurrenceType? recurrenceType,
    List<int>? weeklyDays,
    int? monthlyDay,
    List<String>? completedDates,
    bool isStopped = false,
  }) {
    final rec = recurrenceType ?? (
      goalType == GoalType.daily ? RecurrenceType.daily :
      goalType == GoalType.weekly ? RecurrenceType.weekly :
      goalType == GoalType.monthly ? RecurrenceType.monthly : RecurrenceType.none
    );
    return AppTask._(
      id: id ?? '${DateTime.now().microsecondsSinceEpoch}_${text.hashCode.abs()}',
      text: text,
      done: done,
      reminderTime: reminderTime,
      goalType: goalType,
      category: category,
      points: points,
      createdAt: createdAt ?? DateTime.now(),
      completedAt: completedAt,
      recurrenceType: rec,
      weeklyDays: weeklyDays ?? [],
      monthlyDay: monthlyDay,
      completedDates: completedDates ?? [],
      isStopped: isStopped,
    );
  }

  static String formatDateKey(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  bool get isRecurring => recurrenceType != RecurrenceType.none;

  String get recurrenceLabel {
    switch (recurrenceType) {
      case RecurrenceType.none: return 'Does not repeat';
      case RecurrenceType.daily: return 'Daily';
      case RecurrenceType.weekly: return 'Weekly';
      case RecurrenceType.monthly: return 'Monthly';
    }
  }

  bool isCompletedOn(DateTime dt) {
    return completedDates.contains(formatDateKey(dt));
  }

  bool get isCompletedToday => isCompletedOn(DateTime.now());

  bool isDueOn(DateTime dt) {
    if (isStopped) return false;
    if (recurrenceType == RecurrenceType.none) return !done;
    if (recurrenceType == RecurrenceType.daily) return true;
    if (recurrenceType == RecurrenceType.weekly) {
      return weeklyDays.isEmpty || weeklyDays.contains(dt.weekday);
    }
    if (recurrenceType == RecurrenceType.monthly) {
      if (monthlyDay == null) return true;
      if (dt.day == monthlyDay) return true;
      final lastDay = DateTime(dt.year, dt.month + 1, 0).day;
      if (monthlyDay! > lastDay && dt.day == lastDay) return true;
      return false;
    }
    return true;
  }

  AppTask copyWith({
    String? text,
    bool? done,
    DateTime? reminderTime,
    bool clearReminder = false,
    GoalType? goalType,
    String? category,
    int? points,
    DateTime? completedAt,
    bool clearCompleted = false,
    RecurrenceType? recurrenceType,
    List<int>? weeklyDays,
    int? monthlyDay,
    bool clearMonthlyDay = false,
    List<String>? completedDates,
    bool? isStopped,
  }) => AppTask._(
    id: id,
    text: text ?? this.text,
    done: done ?? this.done,
    reminderTime: clearReminder ? null : (reminderTime ?? this.reminderTime),
    goalType: goalType ?? this.goalType,
    category: category ?? this.category,
    points: points ?? this.points,
    createdAt: createdAt,
    completedAt: clearCompleted ? null : (completedAt ?? this.completedAt),
    recurrenceType: recurrenceType ?? this.recurrenceType,
    weeklyDays: weeklyDays ?? this.weeklyDays,
    monthlyDay: clearMonthlyDay ? null : (monthlyDay ?? this.monthlyDay),
    completedDates: completedDates ?? this.completedDates,
    isStopped: isStopped ?? this.isStopped,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'done': done,
    'reminderTime': reminderTime?.toIso8601String(),
    'goalType': goalType.index,
    'category': category,
    'points': points,
    'createdAt': createdAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'recurrenceType': recurrenceType.index,
    'weeklyDays': weeklyDays,
    'monthlyDay': monthlyDay,
    'completedDates': completedDates,
    'isStopped': isStopped,
  };

  factory AppTask.fromJson(Map<String, dynamic> j) {
    final gtIndex = j['goalType'] ?? 0;
    final GoalType gt = GoalType.values[gtIndex < GoalType.values.length ? gtIndex : 0];
    
    RecurrenceType rec;
    if (j['recurrenceType'] != null) {
      final rIndex = j['recurrenceType'] as int;
      rec = RecurrenceType.values[rIndex < RecurrenceType.values.length ? rIndex : 0];
    } else {
      rec = gt == GoalType.daily ? RecurrenceType.daily :
            gt == GoalType.weekly ? RecurrenceType.weekly :
            gt == GoalType.monthly ? RecurrenceType.monthly : RecurrenceType.none;
    }

    return AppTask(
      id: j['id'],
      text: j['text'],
      done: j['done'] ?? false,
      reminderTime: j['reminderTime'] != null ? DateTime.parse(j['reminderTime']) : null,
      goalType: gt,
      category: j['category'] ?? 'general',
      points: j['points'] ?? 10,
      createdAt: DateTime.parse(j['createdAt']),
      completedAt: j['completedAt'] != null ? DateTime.parse(j['completedAt']) : null,
      recurrenceType: rec,
      weeklyDays: (j['weeklyDays'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [],
      monthlyDay: j['monthlyDay'] as int?,
      completedDates: (j['completedDates'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      isStopped: j['isStopped'] ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppTask && other.id == id && other.done == done && other.isStopped == isStopped && completedDates.length == other.completedDates.length;

  @override
  int get hashCode => Object.hash(id, done, isStopped, completedDates.length);
}

// ═══════════════════════════════════════════════════════════════════════════
//  UNIFIED NOTE MODEL (text or checklist)
// ═══════════════════════════════════════════════════════════════════════════

class ChecklistItem {
  final String id;
  final String title;
  final bool isComplete;

  ChecklistItem({
    String? id,
    required this.title,
    this.isComplete = false,
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString();

  ChecklistItem copyWith({
    String? title,
    bool? isComplete,
  }) => ChecklistItem(
    id: this.id,
    title: title ?? this.title,
    isComplete: isComplete ?? this.isComplete,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'isComplete': isComplete,
  };

  factory ChecklistItem.fromJson(Map<String, dynamic> j) => ChecklistItem(
    id: j['id'],
    title: j['title'] ?? '',
    isComplete: j['isComplete'] ?? false,
  );
}

class Note {
  final String   id;
  final String   title;
  final String   body; // for text notes
  final String   type; // 'text' or 'checklist'
  final List<ChecklistItem> checklistItems; // for checklist notes
  final DateTime createdAt;
  final DateTime? reminderTime;
  final RecurrenceType reminderRepeat;
  final bool     isCompleted;
  final DateTime? completedAt;

  Note({
    String? id,
    required this.title,
    this.body = '',
    this.type = 'text',
    this.checklistItems = const [],
    DateTime? createdAt,
    this.reminderTime,
    this.reminderRepeat = RecurrenceType.none,
    this.isCompleted = false,
    this.completedAt,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        createdAt = createdAt ?? DateTime.now();

  Note copyWith({
    String?   title,
    String?   body,
    String?   type,
    List<ChecklistItem>? checklistItems,
    DateTime? reminderTime,
    RecurrenceType? reminderRepeat,
    bool      clearReminder = false,
    bool?     isCompleted,
    DateTime? completedAt,
  }) => Note(
    id: id,
    createdAt: createdAt,
    title:        title ?? this.title,
    body:         body  ?? this.body,
    type:         type  ?? this.type,
    checklistItems: checklistItems ?? this.checklistItems,
    reminderTime: clearReminder ? null : (reminderTime ?? this.reminderTime),
    reminderRepeat: reminderRepeat ?? this.reminderRepeat,
    isCompleted:  isCompleted ?? this.isCompleted,
    completedAt:  completedAt ?? this.completedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'type': type,
    'checklistItems': checklistItems.map((i) => i.toJson()).toList(),
    'createdAt':    createdAt.toIso8601String(),
    'reminderTime': reminderTime?.toIso8601String(),
    'reminderRepeat': reminderRepeat.index,
    'isCompleted':  isCompleted,
    'completedAt':  completedAt?.toIso8601String(),
  };

  factory Note.fromJson(Map<String, dynamic> j) => Note(
    id:          j['id'],
    title:       j['title'],
    body:        j['body']     ?? '',
    type:        j['type']     ?? 'text',
    checklistItems: (j['checklistItems'] as List<dynamic>?)
        ?.map((i) => ChecklistItem.fromJson(i))
        .toList() ?? [],
    createdAt:   DateTime.parse(j['createdAt']),
    reminderTime: j['reminderTime'] != null
        ? DateTime.parse(j['reminderTime']) : null,
    reminderRepeat: RecurrenceType.none,
    isCompleted: j['isCompleted'] ?? false,
    completedAt: j['completedAt'] != null
        ? DateTime.parse(j['completedAt']) : null,
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  STORAGE
// ═══════════════════════════════════════════════════════════════════════════

class Storage {
  static Future<List<AppTask>> loadTasks() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList('tasks') ?? [])
        .map((e) => AppTask.fromJson(jsonDecode(e))).toList();
  }

  static Future<void> saveTasks(List<AppTask> t) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        'tasks', t.map((e) => jsonEncode(e.toJson())).toList());
  }

  static Future<List<Note>> loadNotes() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList('notes') ?? [])
        .map((e) => Note.fromJson(jsonDecode(e))).toList();
  }

  static Future<void> saveNotes(List<Note> n) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        'notes', n.map((e) => jsonEncode(e.toJson())).toList());
  }

  static Future<int> getPoints() async =>
      (await SharedPreferences.getInstance()).getInt('pts') ?? 0;

  static Future<void> savePoints(int v) async =>
      (await SharedPreferences.getInstance()).setInt('pts', v);
}

// ═══════════════════════════════════════════════════════════════════════════
//  THEME
// ═══════════════════════════════════════════════════════════════════════════

class T {
  static const primary = Color(0xFF6C63FF);
  static const accent  = Color(0xFF00D9A3);
  static const bg      = Color(0xFFF5F6FA);
  static const text    = Color(0xFF1A1A2E);
  static const sub     = Color(0xFF6B7280);
  static const danger  = Color(0xFFFF6B6B);

  static ThemeData get theme => ThemeData(
    scaffoldBackgroundColor: bg,
    primaryColor: primary,
    colorScheme: const ColorScheme.light(primary: primary, secondary: accent),
    appBarTheme: const AppBarTheme(
        backgroundColor: primary, foregroundColor: Colors.white,
        elevation: 0, centerTitle: true),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary, foregroundColor: Colors.white),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary, foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: Colors.white,
      border:        _ob(const Color(0xFFE5E7EB)),
      enabledBorder: _ob(const Color(0xFFE5E7EB)),
      focusedBorder: _ob(primary, w: 2),
    ),
    cardTheme: CardThemeData(
      color: Colors.white, elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.symmetric(vertical: 6),
    ),
    useMaterial3: false,
  );

  static OutlineInputBorder _ob(Color c, {double w = 1}) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c, width: w));
}

// ═══════════════════════════════════════════════════════════════════════════
//  HELPERS
// ═══════════════════════════════════════════════════════════════════════════

Color catColor(String c) {
  switch (c) {
    case 'shopping': return const Color(0xFFF59E0B);
    case 'general':
    default:         return T.primary;
  }
}

IconData catIcon(String c) {
  switch (c) {
    case 'shopping': return Icons.shopping_cart_rounded;
    case 'general':
    default:         return Icons.task_alt_rounded;
  }
}

String fmtTime(DateTime dt) {
  final h  = dt.hour;
  final m  = dt.minute.toString().padLeft(2, '0');
  final ap = h >= 12 ? 'PM' : 'AM';
  final hr = h > 12 ? h - 12 : (h == 0 ? 12 : h);
  return '$hr:$m $ap';
}

String fmtDT(DateTime dt) {
  const mo = ['','Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec'];
  return '${mo[dt.month]} ${dt.day}, ${fmtTime(dt)}';
}

Future<bool> confirmDelete(BuildContext ctx, String what) async {
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: T.danger),
        const SizedBox(width: 8),
        Text('Delete $what?'),
      ]),
      content: Text('This $what will be permanently deleted.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: T.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok == true;
}

void showSnack(BuildContext ctx, String msg, {bool isError = false}) {
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: isError ? T.danger : null,
    duration: const Duration(seconds: 2),
  ));
}

String fmtTimeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${(diff.inDays / 7).floor()}w ago';
}

// ═══════════════════════════════════════════════════════════════════════════
//  MAIN
// ═══════════════════════════════════════════════════════════════════════════

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  await taskStore.load();
  await noteStore.load();
  await rescheduleAllNotifications();
  runApp(const DoItApp());
}

class DoItApp extends StatelessWidget {
  const DoItApp({super.key});
  @override
  Widget build(BuildContext ctx) => MaterialApp(
    title: 'DoIt',
    debugShowCheckedModeBanner: false,
    theme: T.theme,
    home: const HomeShell(),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  HOME SHELL — Bottom nav with IndexedStack
// ═══════════════════════════════════════════════════════════════════════════

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _i = 0;

  void _navigateTo(int index) {
    setState(() => _i = index);
  }

  @override
  Widget build(BuildContext ctx) => Scaffold(
    body: IndexedStack(
      index: _i,
      children: [
        HomePage(onNavigate: _navigateTo),
        const TasksPage(),
        const NotesPage(),
        const ProgressPage(),
      ],
    ),
    bottomNavigationBar: BottomNavigationBar(
      currentIndex: _i,
      onTap: (i) => setState(() => _i = i),
      type: BottomNavigationBarType.fixed,
      selectedItemColor: T.primary,
      unselectedItemColor: T.sub,
      items: const [
        BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded), label: 'Home'),
        BottomNavigationBarItem(
            icon: Icon(Icons.check_circle_outline_rounded), label: 'Tasks'),
        BottomNavigationBarItem(
            icon: Icon(Icons.note_rounded), label: 'Notes'),
        BottomNavigationBarItem(
            icon: Icon(Icons.trending_up_rounded), label: 'Progress'),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  HOME PAGE — NEW REDESIGNED LAYOUT
//  • Primary actions (New note + New checklist)
//  • Quick access cards (Recent, Active)
//  • Weekly stats grid
// ═══════════════════════════════════════════════════════════════════════════

class HomePage extends StatefulWidget {
  final ValueChanged<int>? onNavigate;
  const HomePage({super.key, this.onNavigate});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    taskStore.addListener(_rebuild);
    noteStore.addListener(_rebuild);
  }

  @override
  void dispose() {
    taskStore.removeListener(_rebuild);
    noteStore.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good Morning! ☀️';
    if (h < 17) return 'Good Afternoon! 🌤';
    return 'Good Evening! 🌙';
  }

  List<Note> get _recentNotes {
    final sorted = List<Note>.from(noteStore.value)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted.take(3).toList();
  }

  List<Note> get _activeChecklists {
    final sorted = noteStore.value
        .where((n) => n.type == 'checklist' && !n.isCompleted)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted.take(3).toList();
  }

  int get _checklistProgress {
    int done = 0;
    for (final note in noteStore.value) {
      if (note.type == 'checklist') {
        done += note.checklistItems.where((i) => i.isComplete).length;
      }
    }
    return done;
  }

  int get _checklistTotal {
    int total = 0;
    for (final note in noteStore.value) {
      if (note.type == 'checklist') {
        total += note.checklistItems.length;
      }
    }
    return total;
  }

  @override
  Widget build(BuildContext ctx) {
    final notes = noteStore.value;
    final tasks = taskStore.value;
    final activeTasks = tasks.where((t) => !t.isStopped && !t.done).length;
    final todayDone = tasks.where((t) => t.isCompletedToday || (t.done && t.completedAt != null && AppTask.formatDateKey(t.completedAt!) == AppTask.formatDateKey(DateTime.now()))).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('DoIt'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            onPressed: () async {
              await Navigator.push(ctx,
                  MaterialPageRoute(builder: (_) => const SettingsPage()));
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await taskStore.load();
          await noteStore.load();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Greeting + Quick stats
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: T.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: T.primary.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_greeting,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text('${notes.length} notes · $activeTasks active tasks',
                        style: const TextStyle(
                            fontSize: 13, color: T.sub)),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // PRIMARY ACTIONS
              Row(
                children: [
                  Expanded(
                    child: _buildPrimaryActionButton(
                      ctx,
                      title: 'New note',
                      subtitle: 'Start writing',
                      icon: '✏️',
                      color: T.primary,
                      isHighlighted: true,
                      onTap: () => _goToNoteEditor(ctx, null, 'text'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildPrimaryActionButton(
                      ctx,
                      title: 'New task',
                      subtitle: 'Add to tasks',
                      icon: '☑️',
                      color: T.accent,
                      isHighlighted: false,
                      onTap: () => _addTaskHome(ctx),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // QUICK ACCESS
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Quick access',
                      style: Theme.of(ctx).textTheme.titleMedium),
                  TextButton(
                    onPressed: () => widget.onNavigate?.call(2),
                    child: const Text('View All', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _buildQuickAccessCard(
                      title: 'Recent notes',
                      count: '${_recentNotes.length}',
                      notesList: _recentNotes,
                      icon: Icons.note_rounded,
                      onHeaderTap: () => widget.onNavigate?.call(2),
                      onItemTap: (n) => _goToNoteEditor(ctx, n, n.type),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildQuickAccessCard(
                      title: 'Active checklists',
                      count: '$_checklistProgress/$_checklistTotal',
                      notesList: _activeChecklists,
                      icon: Icons.checklist_rounded,
                      onHeaderTap: () => widget.onNavigate?.call(2),
                      onItemTap: (n) => _goToNoteEditor(ctx, n, n.type),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // STATS GRID
              Text('This week',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 10),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.85,
                children: [
                  _buildStatCard('${notes.length}', 'Notes',
                      onTap: () => widget.onNavigate?.call(2)),
                  _buildStatCard(
                      '${noteStore.value.where((n) => n.type == 'checklist').length}',
                      'Lists',
                      onTap: () => widget.onNavigate?.call(2)),
                  _buildStatCard('$activeTasks', 'Tasks',
                      onTap: () => widget.onNavigate?.call(1)),
                  _buildStatCard(
                      '$todayDone',
                      'Done',
                      onTap: () => widget.onNavigate?.call(3)),
                ],
              ),

              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryActionButton(
      BuildContext ctx, {
        required String title,
        required String subtitle,
        required String icon,
        required Color color,
        required bool isHighlighted,
        required VoidCallback onTap,
      }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 88,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isHighlighted ? color : Colors.white,
          border: Border.all(
            color: color.withOpacity(0.3),
            width: isHighlighted ? 2 : 0.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isHighlighted ? Colors.white : T.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: isHighlighted ? Colors.white70 : T.sub,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(icon, style: const TextStyle(fontSize: 28)),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAccessCard({
    required String title,
    required String count,
    required List<Note> notesList,
    required IconData icon,
    required VoidCallback onHeaderTap,
    required ValueChanged<Note> onItemTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onHeaderTap,
            child: Row(
              children: [
                Icon(icon, size: 16, color: T.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: T.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(count,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: T.primary)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (notesList.isEmpty)
            const Text('None yet', style: TextStyle(fontSize: 11, color: T.sub))
          else
            ...notesList.take(2).map((n) => InkWell(
              onTap: () => onItemTap(n),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                child: Row(
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                        color: T.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        n.title.isEmpty ? 'Untitled' : n.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: T.text,
                          fontWeight: FontWeight.w500,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )),
        ],
      ),
    );
  }

  Widget _buildStatCard(String value, String label, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: T.sub),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _goToNoteEditor(
      BuildContext ctx, Note? existing, String initialType) async {
    final result = await Navigator.push<Note>(
      context,
      MaterialPageRoute(
        builder: (_) => UnifiedNoteEditorPage(
          note: existing,
          initialType: initialType,
        ),
      ),
    );

    if (result == null) return;

    if (existing != null) {
      if (existing.reminderTime != null) {
        await cancelNotif(existing.id.hashCode);
      }
      await noteStore.update(result);
    } else {
      await noteStore.create(result);
    }

    if (result.reminderTime != null) {
      final notifBody = result.type == 'checklist'
          ? 'Checklist Reminder'
          : 'Note Reminder';
      await scheduleNotif(
        id: result.id.hashCode,
        title: result.title,
        body: notifBody,
        at: result.reminderTime!,
        recurrenceType: result.reminderRepeat,
      );
    }

    if (mounted) {
      showSnack(
        context,
        existing == null ? 'Note created' : 'Note updated',
      );
    }
  }

  Future<void> _addTaskHome(BuildContext ctx) async {
    final result = await Navigator.push<List<AppTask>>(
        ctx,
        MaterialPageRoute(
            builder: (_) => const AddEditTaskPage(defaultGoalType: GoalType.daily)));
    if (result == null || result.isEmpty) return;

    await taskStore.addMultiple(result);
    for (final t in result) {
      if (t.reminderTime != null) {
        final notifBody = "Task Reminder • ${t.recurrenceType.label}";
        await scheduleNotif(
            id: t.id.hashCode,
            title: t.text,
            body: notifBody,
            at: t.reminderTime!,
            repeatType: t.goalType);
      }
    }
    if (mounted) {
      showSnack(ctx, result.length > 1 ? '${result.length} tasks created' : 'Task created');
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  TASKS PAGE (unchanged — same structure as before)
// ═══════════════════════════════════════════════════════════════════════════

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.addListener(() { if (mounted) setState(() {}); });
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  Future<void> _addTask(GoalType gt) async {
    final result = await Navigator.push<List<AppTask>>(
        context,
        MaterialPageRoute(
            builder: (_) => AddEditTaskPage(defaultGoalType: gt)));
    if (result == null || result.isEmpty) return;

    await taskStore.addMultiple(result);
    for (final t in result) {
      if (t.reminderTime != null) {
        final notifBody = "Task Reminder • ${t.recurrenceType.label}";
        await scheduleNotif(
            id: t.id.hashCode,
            title: t.text,
            body: notifBody,
            at: t.reminderTime!,
            repeatType: t.goalType);
      }
    }
    if (mounted) {
      showSnack(context, result.length > 1 ? '${result.length} tasks created' : 'Task created');
    }
  }

  @override
  Widget build(BuildContext ctx) => Scaffold(
    appBar: AppBar(
      title: const Text('Tasks'),
      bottom: TabBar(
        controller: _tab,
        indicatorColor: Colors.white,
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white60,
        tabs: const [
          Tab(text: 'Daily'),
          Tab(text: 'Weekly'),
          Tab(text: 'Monthly'),
          Tab(text: 'Done / Stopped'),
        ],
      ),
    ),
    body: TabBarView(
      controller: _tab,
      children: [
        _TaskTabView(key: const ValueKey('daily'),   tabIndex: 0),
        _TaskTabView(key: const ValueKey('weekly'),  tabIndex: 1),
        _TaskTabView(key: const ValueKey('monthly'), tabIndex: 2),
        _TaskTabView(key: const ValueKey('done'),    tabIndex: 3),
      ],
    ),
    floatingActionButton: _tab.index < 3
        ? FloatingActionButton.extended(
        onPressed: () => _addTask(GoalType.values[_tab.index]),
        icon: const Icon(Icons.add),
        label: const Text('Add Task'))
        : null,
  );
}

class _TaskTabView extends StatefulWidget {
  final int tabIndex;
  const _TaskTabView({
    required super.key,
    required this.tabIndex,
  });

  @override
  State<_TaskTabView> createState() => _TaskTabViewState();
}

class _TaskTabViewState extends State<_TaskTabView>
    with AutomaticKeepAliveClientMixin {

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    taskStore.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    taskStore.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  List<AppTask> get _filtered {
    final all = taskStore.value;
    List<AppTask> list;
    if (widget.tabIndex == 3) {
      list = all.where((t) => t.done || t.isStopped).toList()
        ..sort((a, b) =>
            (b.completedAt ?? b.createdAt)
                .compareTo(a.completedAt ?? a.createdAt));
    } else {
      final gt = GoalType.values[widget.tabIndex];
      final rec = widget.tabIndex == 0 ? RecurrenceType.daily :
                  widget.tabIndex == 1 ? RecurrenceType.weekly : RecurrenceType.monthly;

      list = all.where((t) => !t.isStopped && !t.done && (t.recurrenceType == rec || t.goalType == gt)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  Future<void> _toggle(String taskId) async {
    await taskStore.toggle(taskId);
  }

  Future<void> _delete(AppTask t) async {
    final ok = await confirmDelete(context, 'Task');
    if (!ok) return;
    if (t.reminderTime != null) await cancelNotif(t.id.hashCode);
    await taskStore.remove(t.id);
    if (mounted) showSnack(context, 'Task deleted');
  }

  Future<void> _edit(AppTask t) async {
    final result = await Navigator.push<List<AppTask>>(
        context,
        MaterialPageRoute(
            builder: (_) => AddEditTaskPage(existing: t)));
    if (result == null || result.isEmpty) return;
    final updated = result.first;

    await cancelNotif(t.id.hashCode);
    if (updated.reminderTime != null) {
      final notifBody = "Task Reminder • ${updated.recurrenceType.label}";
      await scheduleNotif(
          id: updated.id.hashCode,
          title: updated.text,
          body: notifBody,
          at: updated.reminderTime!,
          repeatType: updated.goalType);
    }
    await taskStore.replace(updated);
    if (mounted) showSnack(context, 'Task updated');
  }

  Future<void> _stopRecurring(AppTask t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.stop_circle_outlined, color: T.danger),
          SizedBox(width: 8),
          Text('Stop Recurring Task?'),
        ]),
        content: const Text(
          'Stop this recurring task? It will no longer appear or send notifications in the future. Previous progress will remain in your history.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: T.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop Task'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await taskStore.stopRecurringTask(t.id);
      if (mounted) showSnack(context, 'Recurring task stopped');
    }
  }

  @override
  Widget build(BuildContext ctx) {
    super.build(ctx);
    final tasks  = _filtered;
    final isDone = widget.tabIndex == 3;

    if (tasks.isEmpty) {
      return Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(isDone ? Icons.emoji_events_rounded : Icons.task_alt,
              size: 64, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(isDone ? 'No completed or stopped tasks yet' : 'No tasks here yet',
              style: TextStyle(color: Colors.grey[400], fontSize: 16)),
        ],
      ));
    }

    return RefreshIndicator(
      onRefresh: () => taskStore.load(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        itemCount: tasks.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) return _header(tasks.length);
          final task = tasks[i - 1];
          return _TaskCard(
            key: ValueKey(task.id),
            task: task,
            onToggle: () => _toggle(task.id),
            onEdit:   () => _edit(task),
            onDelete: () => _delete(task),
            onStopRecurring: () => _stopRecurring(task),
          );
        },
      ),
    );
  }

  Widget _header(int count) {
    final isDone = widget.tabIndex == 3;
    final color  = isDone ? T.accent : GoalType.values[widget.tabIndex].color;
    final icon   = isDone
        ? Icons.check_circle_rounded
        : GoalType.values[widget.tabIndex].icon;
    final label  = isDone ? 'Done / Stopped' : GoalType.values[widget.tabIndex].label;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text('$label Tasks',
            style: TextStyle(color: color,
                fontWeight: FontWeight.bold, fontSize: 14)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(20)),
          child: Text('$count',
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      ]),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final AppTask task;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onStopRecurring;

  const _TaskCard({
    required super.key,
    required this.task,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    this.onStopRecurring,
  });

  @override
  Widget build(BuildContext ctx) {
    final isChecked = task.isRecurring ? task.isCompletedToday : task.done;
    const dayNames = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    String recurrenceDetails = '';
    if (task.recurrenceType == RecurrenceType.weekly && task.weeklyDays.isNotEmpty) {
      final daysStr = task.weeklyDays.map((d) => dayNames[d]).join(', ');
      recurrenceDetails = ' ($daysStr)';
    } else if (task.recurrenceType == RecurrenceType.monthly && task.monthlyDay != null) {
      recurrenceDetails = ' (Day ${task.monthlyDay})';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: onToggle,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 26, height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isChecked ? T.accent : Colors.transparent,
                  border: Border.all(
                      color: isChecked ? T.accent : Colors.grey[400]!, width: 2),
                ),
                child: isChecked
                    ? const Icon(Icons.check_rounded,
                    color: Colors.white, size: 16)
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    task.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      decoration: (!task.isRecurring && task.done) ? TextDecoration.lineThrough : null,
                      color: (!task.isRecurring && task.done) ? T.sub : T.text,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _ptBadge(task.points),
                      if (task.isStopped)
                        _badge('Stopped', T.danger)
                      else
                        _badge('${task.recurrenceType.label}$recurrenceDetails', task.goalType.color),
                      if (task.isRecurring && task.isCompletedToday)
                        _badge('✓ Completed today', T.accent),
                      if (task.reminderTime != null)
                        _badge('⏰ ${fmtTime(task.reminderTime!)}', T.primary),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18, color: T.sub),
                  tooltip: 'Edit',
                  onPressed: onEdit,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
                if (task.isRecurring && !task.isStopped && onStopRecurring != null)
                  IconButton(
                    icon: const Icon(Icons.stop_circle_outlined, size: 18, color: T.sub),
                    tooltip: 'Stop Recurring Task',
                    onPressed: onStopRecurring,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 18, color: T.danger),
                  tooltip: 'Delete',
                  onPressed: onDelete,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String l, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
        color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
    child: Text(l,
        style: TextStyle(fontSize: 10, color: c,
            fontWeight: FontWeight.w600)),
  );

  Widget _ptBadge(int pts) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.star_rounded, color: Colors.amber, size: 12),
      const SizedBox(width: 2),
      Text('$pts',
          style: const TextStyle(fontSize: 11,
              fontWeight: FontWeight.bold, color: Colors.amber)),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  TIME PARSING HELPERS
// ═══════════════════════════════════════════════════════════════════════════

/// Parses a manually entered time string like "6:00 AM", "18:00", "5 PM", "6:30"
/// into a [TimeOfDay]. Returns null if parsing fails.
TimeOfDay? parseManualTimeString(String input) {
  final s = input.trim().toLowerCase();
  if (s.isEmpty) return null;

  // Try HH:MM AM/PM or H:MM AM/PM
  final ampmFull = RegExp(r'^(\d{1,2}):(\d{2})\s*(am|pm)$');
  final m1 = ampmFull.firstMatch(s);
  if (m1 != null) {
    int h = int.parse(m1.group(1)!);
    final min = int.parse(m1.group(2)!);
    final period = m1.group(3)!;
    if (period == 'pm' && h < 12) h += 12;
    if (period == 'am' && h == 12) h = 0;
    if (h < 24 && min < 60) return TimeOfDay(hour: h, minute: min);
  }

  // Try H AM/PM or HH AM/PM (no colon)
  final ampmShort = RegExp(r'^(\d{1,2})\s*(am|pm)$');
  final m2 = ampmShort.firstMatch(s);
  if (m2 != null) {
    int h = int.parse(m2.group(1)!);
    final period = m2.group(2)!;
    if (period == 'pm' && h < 12) h += 12;
    if (period == 'am' && h == 12) h = 0;
    if (h < 24) return TimeOfDay(hour: h, minute: 0);
  }

  // Try HH:MM 24h
  final tfull = RegExp(r'^(\d{1,2}):(\d{2})$');
  final m3 = tfull.firstMatch(s);
  if (m3 != null) {
    final h = int.parse(m3.group(1)!);
    final min = int.parse(m3.group(2)!);
    if (h < 24 && min < 60) return TimeOfDay(hour: h, minute: min);
  }

  // Try bare hour like "6" or "18"
  final bareHour = RegExp(r'^(\d{1,2})$');
  final m4 = bareHour.firstMatch(s);
  if (m4 != null) {
    final h = int.parse(m4.group(1)!);
    if (h < 24) return TimeOfDay(hour: h, minute: 0);
  }

  return null;
}

/// Format a [TimeOfDay] to "6:00 AM" style string.
String formatTOD(TimeOfDay t) {
  final h12 = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  final min = t.minute.toString().padLeft(2, '0');
  final period = t.period == DayPeriod.am ? 'AM' : 'PM';
  return '$h12:$min $period';
}

/// Parses a task line like "6-7 Coding", "9:30-10:30 Study", "6:00 AM - 7:00 AM LeetCode"
/// Returns a [ParsedLine] with extracted title, startTime, endTime.
ParsedLine parseTaskLine(String line) {
  // Pattern: "H-H Title" or "H:MM-H:MM Title" or "H AM-H PM Title" etc.
  // We try to extract a leading time range or single time, then treat the rest as title.

  // Range with optional colon: "6-7", "6:00-7:00", "6:30-7:30"
  final rangeBasic = RegExp(r'^(\d{1,2}(?::\d{2})?)\s*[-–]\s*(\d{1,2}(?::\d{2})?)\s*(.*)$');
  final m1 = rangeBasic.firstMatch(line.trim());
  if (m1 != null) {
    final start = parseManualTimeString(m1.group(1)!);
    final end   = parseManualTimeString(m1.group(2)!);
    final title = m1.group(3)!.trim();
    return ParsedLine(title: title.isEmpty ? line.trim() : title, start: start, end: end);
  }

  // Range with AM/PM: "6:00 AM - 7:00 AM Coding"
  final rangeAmPm = RegExp(
      r'^(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*[-–]\s*(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*(.*)$',
      caseSensitive: false);
  final m2 = rangeAmPm.firstMatch(line.trim());
  if (m2 != null) {
    final start = parseManualTimeString(m2.group(1)!);
    final end   = parseManualTimeString(m2.group(2)!);
    final title = m2.group(3)!.trim();
    return ParsedLine(title: title.isEmpty ? line.trim() : title, start: start, end: end);
  }

  // Single time prefix: "6:00 Coding", "9 AM Study"
  final singleTime = RegExp(
      r'^(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*(.*)$',
      caseSensitive: false);
  final m3 = singleTime.firstMatch(line.trim());
  if (m3 != null) {
    final start = parseManualTimeString(m3.group(1)!);
    final title = m3.group(2)!.trim();
    if (start != null && title.isNotEmpty) {
      return ParsedLine(title: title, start: start, end: null);
    }
  }

  return ParsedLine(title: line.trim(), start: null, end: null);
}

class ParsedLine {
  final String title;
  final TimeOfDay? start;
  final TimeOfDay? end;
  const ParsedLine({required this.title, this.start, this.end});
}

// ═══════════════════════════════════════════════════════════════════════════
//  DRAFT TASK MODEL — represents one individual task in a multi-task entry
// ═══════════════════════════════════════════════════════════════════════════
class _DraftTask {
  final TextEditingController textCtrl;
  final TextEditingController manualTimeCtrl;
  TimeOfDay? startTime;
  TimeOfDay? endTime;
  DateTime? reminderTime;

  _DraftTask({
    String text = '',
    this.startTime,
    this.endTime,
  })  : textCtrl = TextEditingController(text: text),
        manualTimeCtrl = TextEditingController(
          text: _buildTimeLabel(startTime, endTime),
        );

  static String _buildTimeLabel(TimeOfDay? start, TimeOfDay? end) {
    if (start == null) return '';
    if (end == null) return formatTOD(start);
    return '${formatTOD(start)} – ${formatTOD(end)}';
  }

  void dispose() {
    textCtrl.dispose();
    manualTimeCtrl.dispose();
  }

  /// Sync reminder to startTime on the current date (or today for recurring).
  void syncReminderFromStart() {
    if (startTime == null) {
      reminderTime = null;
      return;
    }
    final now = DateTime.now();
    reminderTime = DateTime(now.year, now.month, now.day, startTime!.hour, startTime!.minute);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ADD/EDIT TASK PAGE
// ═══════════════════════════════════════════════════════════════════════════

class AddEditTaskPage extends StatefulWidget {
  final AppTask? existing;
  final GoalType defaultGoalType;
  const AddEditTaskPage({
    super.key,
    this.existing,
    this.defaultGoalType = GoalType.daily,
  });
  @override
  State<AddEditTaskPage> createState() => _AddEditState();
}

class _AddEditState extends State<AddEditTaskPage> {
  late TextEditingController _ctrl;
  late TextEditingController _manualTimeCtrl;
  final String _cat = 'general';
  late GoalType _gt;
  late RecurrenceType _recType;
  late List<int> _weeklyDays;
  late int _monthlyDay;
  late int _pts;
  DateTime? _rem;
  bool _createMultiple = false;

  // Multi-task draft list (used when _createMultiple == true and multi-line)
  List<_DraftTask> _drafts = [];
  bool _draftsBuilt = false;

  bool get _editing => widget.existing != null;

  // Whether we are currently in multi-task draft editing mode
  bool get _inDraftMode => !_editing && _createMultiple && _drafts.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _ctrl = TextEditingController(text: e?.text ?? '');
    _manualTimeCtrl = TextEditingController(
        text: e?.reminderTime != null ? formatTOD(TimeOfDay.fromDateTime(e!.reminderTime!)) : '');
    _gt   = e?.goalType ?? widget.defaultGoalType;
    _recType = e?.recurrenceType ?? (
      _gt == GoalType.daily ? RecurrenceType.daily :
      _gt == GoalType.weekly ? RecurrenceType.weekly :
      _gt == GoalType.monthly ? RecurrenceType.monthly : RecurrenceType.none
    );
    _weeklyDays = List<int>.from(e?.weeklyDays ?? [DateTime.now().weekday]);
    if (_weeklyDays.isEmpty) _weeklyDays = [DateTime.now().weekday];
    _monthlyDay = e?.monthlyDay ?? DateTime.now().day;
    _pts  = e?.points   ?? 10;
    _rem  = e?.reminderTime;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _manualTimeCtrl.dispose();
    for (final d in _drafts) { d.dispose(); }
    super.dispose();
  }

  // ── Single-task reminder picker (existing flow, unchanged) ──

  Future<void> _pickReminder() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _rem ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(minutes: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _rem != null
          ? TimeOfDay.fromDateTime(_rem!)
          : TimeOfDay.now(),
    );
    if (time == null) return;
    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      _rem = dt;
      _manualTimeCtrl.text = formatTOD(time);
    });
  }

  // Parse manual time string for single-task mode
  void _applyManualTime(String value) {
    final tod = parseManualTimeString(value);
    if (tod != null) {
      final now = DateTime.now();
      setState(() {
        _rem = DateTime(now.year, now.month, now.day, tod.hour, tod.minute);
      });
    }
  }

  // ── Build draft tasks from multi-line text ──

  void _buildDrafts() {
    // Dispose old
    for (final d in _drafts) { d.dispose(); }
    _drafts = [];

    final lines = _ctrl.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    for (final line in lines) {
      final parsed = parseTaskLine(line);
      final draft = _DraftTask(
        text: parsed.title,
        startTime: parsed.start,
        endTime: parsed.end,
      );
      // Auto-set reminder to start time if available
      draft.syncReminderFromStart();
      _drafts.add(draft);
    }
    _draftsBuilt = true;
  }

  // ── Per-draft picker ──

  Future<void> _pickDraftReminder(int index) async {
    final draft = _drafts[index];
    final initialDt = draft.reminderTime;
    final date = await showDatePicker(
      context: context,
      initialDate: initialDt ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(minutes: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: initialDt != null ? TimeOfDay.fromDateTime(initialDt) : TimeOfDay.now(),
    );
    if (time == null || !mounted) return;
    setState(() {
      draft.startTime = time;
      draft.reminderTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      draft.manualTimeCtrl.text = formatTOD(time);
    });
  }

  void _applyDraftManualTime(int index, String value) {
    final tod = parseManualTimeString(value);
    if (tod != null) {
      final now = DateTime.now();
      setState(() {
        _drafts[index].startTime = tod;
        _drafts[index].reminderTime = DateTime(now.year, now.month, now.day, tod.hour, tod.minute);
      });
    }
  }

  // ── Save ──

  void _save() {
    // --- Multi-task draft mode ---
    if (_inDraftMode) {
      final tasks = <AppTask>[];
      for (final draft in _drafts) {
        final title = draft.textCtrl.text.trim();
        if (title.isEmpty) continue;

        GoalType computedGt = _gt;
        if (_recType == RecurrenceType.daily) computedGt = GoalType.daily;
        if (_recType == RecurrenceType.weekly) computedGt = GoalType.weekly;
        if (_recType == RecurrenceType.monthly) computedGt = GoalType.monthly;

        tasks.add(AppTask(
          text: title,
          category: _cat,
          goalType: computedGt,
          recurrenceType: _recType,
          weeklyDays: _recType == RecurrenceType.weekly ? _weeklyDays : [],
          monthlyDay: _recType == RecurrenceType.monthly ? _monthlyDay : null,
          points: _pts,
          reminderTime: draft.reminderTime,
        ));
      }
      if (tasks.isEmpty) {
        showSnack(context, 'Please enter at least one task', isError: true);
        return;
      }
      Navigator.pop(context, tasks);
      return;
    }

    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      showSnack(context, 'Please enter a task description', isError: true);
      return;
    }

    // --- Legacy multi-line mode (toggle on but drafts not built) ---
    if (!_editing && _createMultiple && text.contains('\n')) {
      final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      if (lines.isEmpty) return;

      final tasks = lines.map((line) {
        GoalType computedGt = _gt;
        if (_recType == RecurrenceType.daily) computedGt = GoalType.daily;
        if (_recType == RecurrenceType.weekly) computedGt = GoalType.weekly;
        if (_recType == RecurrenceType.monthly) computedGt = GoalType.monthly;

        return AppTask(
          text: line,
          category: _cat,
          goalType: computedGt,
          recurrenceType: _recType,
          weeklyDays: _recType == RecurrenceType.weekly ? _weeklyDays : [],
          monthlyDay: _recType == RecurrenceType.monthly ? _monthlyDay : null,
          points: _pts,
          reminderTime: _rem,
        );
      }).toList();

      Navigator.pop(context, tasks);
      return;
    }

    // --- Single task ---
    GoalType computedGt = _gt;
    if (_recType == RecurrenceType.daily) computedGt = GoalType.daily;
    if (_recType == RecurrenceType.weekly) computedGt = GoalType.weekly;
    if (_recType == RecurrenceType.monthly) computedGt = GoalType.monthly;

    final result = _editing
        ? widget.existing!.copyWith(
        text: text, category: _cat,
        goalType: computedGt,
        recurrenceType: _recType,
        weeklyDays: _recType == RecurrenceType.weekly ? _weeklyDays : [],
        monthlyDay: _recType == RecurrenceType.monthly ? _monthlyDay : null,
        clearMonthlyDay: _recType != RecurrenceType.monthly,
        points: _pts,
        reminderTime: _rem, clearReminder: _rem == null)
        : AppTask(
        text: text, category: _cat,
        goalType: computedGt,
        recurrenceType: _recType,
        weeklyDays: _recType == RecurrenceType.weekly ? _weeklyDays : [],
        monthlyDay: _recType == RecurrenceType.monthly ? _monthlyDay : null,
        points: _pts, reminderTime: _rem);

    Navigator.pop(context, [result]);
  }

  @override
  Widget build(BuildContext ctx) {
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final showMultiToggle = !_editing && _ctrl.text.contains('\n');

    // When user toggles createMultiple on and there's multi-line text, build drafts
    if (_createMultiple && _ctrl.text.contains('\n') && !_draftsBuilt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_buildDrafts);
      });
    }
    if (!_createMultiple && _draftsBuilt) {
      _draftsBuilt = false;
      for (final d in _drafts) { d.dispose(); }
      _drafts = [];
    }

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit Task' : 'Add Task')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // ── Task Text Input (hidden when showing drafts) ──
                    if (!_inDraftMode) ...[
                      const Text('Task Description',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _ctrl,
                        maxLines: 4,
                        autofocus: !_editing,
                        onChanged: (_) => setState(() {
                          _draftsBuilt = false;
                        }),
                        decoration: const InputDecoration(
                          hintText: 'Enter task description...\n\nNote: Enter multiple lines to create multiple tasks.',
                        ),
                      ),

                      if (showMultiToggle) ...[
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          value: _createMultiple,
                          onChanged: (val) => setState(() {
                            _createMultiple = val ?? false;
                            _draftsBuilt = false;
                          }),
                          title: const Text('Create each line as a separate task',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('Each task gets its own time & reminder',
                              style: TextStyle(fontSize: 11)),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ],
                    ],

                    // ── Draft Task Cards (multi-task mode) ──
                    if (_inDraftMode) ...[
                      Row(
                        children: [
                          const Expanded(
                            child: Text('Individual Tasks',
                                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                          ),
                          TextButton.icon(
                            onPressed: () => setState(() {
                              _createMultiple = false;
                              _draftsBuilt = false;
                              for (final d in _drafts) { d.dispose(); }
                              _drafts = [];
                            }),
                            icon: const Icon(Icons.edit, size: 14),
                            label: const Text('Edit text', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...List.generate(_drafts.length, (i) {
                        final draft = _drafts[i];
                        return _DraftTaskCard(
                          index: i,
                          draft: draft,
                          onPickTime: () => _pickDraftReminder(i),
                          onRemove: _drafts.length > 1 ? () => setState(() {
                            draft.dispose();
                            _drafts.removeAt(i);
                          }) : null,
                          onUpdate: () => setState(() {}),
                        );
                      }),
                      // Add task button for drafts
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _drafts.add(_DraftTask());
                        }),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Another Task'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 40),
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // ── Recurrence ──
                    const Text('Repeat / Recurrence',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: RecurrenceType.values.map((rt) {
                        final sel = _recType == rt;
                        return ChoiceChip(
                          label: Text(rt.label),
                          selected: sel,
                          selectedColor: T.primary,
                          labelStyle: TextStyle(
                            color: sel ? Colors.white : T.text,
                            fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                          ),
                          onSelected: (s) {
                            if (s) setState(() => _recType = rt);
                          },
                        );
                      }).toList(),
                    ),

                    if (_recType == RecurrenceType.weekly) ...[
                      const SizedBox(height: 16),
                      const Text('Select Days of Week:',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        children: List.generate(7, (idx) {
                          final dayNum = idx + 1;
                          final isSel = _weeklyDays.contains(dayNum);
                          return FilterChip(
                            label: Text(dayNames[idx]),
                            selected: isSel,
                            selectedColor: T.accent,
                            labelStyle: TextStyle(
                              color: isSel ? Colors.white : T.text,
                              fontSize: 12,
                            ),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  _weeklyDays.add(dayNum);
                                } else {
                                  if (_weeklyDays.length > 1) {
                                    _weeklyDays.remove(dayNum);
                                  }
                                }
                              });
                            },
                          );
                        }),
                      ),
                    ],

                    if (_recType == RecurrenceType.monthly) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Text('Day of Month:',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 12),
                          DropdownButton<int>(
                            value: _monthlyDay,
                            items: List.generate(31, (i) => i + 1)
                                .map((d) => DropdownMenuItem(value: d, child: Text('Day $d')))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) setState(() => _monthlyDay = val);
                            },
                          ),
                        ],
                      ),
                    ],

                    // ── Single-task Reminder (shown only when NOT in draft mode) ──
                    if (!_inDraftMode) ...[
                      const SizedBox(height: 20),
                      const Text('Reminder',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      // Existing time picker tile
                      ListTile(
                        tileColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: Color(0xFFE5E7EB))),
                        leading: const Icon(Icons.alarm_rounded, color: T.primary),
                        title: Text(
                          _rem == null ? 'Tap to set reminder time' : fmtDT(_rem!),
                          style: TextStyle(
                              color: _rem == null ? T.sub : T.text,
                              fontWeight: _rem != null ? FontWeight.w600 : FontWeight.normal),
                        ),
                        trailing: _rem != null
                            ? IconButton(
                            icon: const Icon(Icons.clear, color: T.danger),
                            onPressed: () => setState(() => _rem = null))
                            : const Icon(Icons.chevron_right),
                        onTap: _pickReminder,
                      ),
                    ],

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            // Fixed Bottom Submit Area
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    offset: const Offset(0, -2),
                    blurRadius: 6,
                  )
                ],
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _save,
                  icon: Icon(_editing ? Icons.save_rounded : Icons.add_task),
                  label: Text(_editing
                      ? 'Save Changes'
                      : (_inDraftMode
                          ? 'Add ${_drafts.length} Tasks'
                          : (_createMultiple && _ctrl.text.contains('\n')
                              ? 'Add Multiple Tasks'
                              : 'Add Task'))),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  DRAFT TASK CARD — individual task entry in multi-task mode
// ═══════════════════════════════════════════════════════════════════════════

class _DraftTaskCard extends StatelessWidget {
  final int index;
  final _DraftTask draft;
  final VoidCallback onPickTime;
  final VoidCallback? onRemove;
  final VoidCallback onUpdate;

  const _DraftTaskCard({
    required this.index,
    required this.draft,
    required this.onPickTime,
    required this.onUpdate,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hasReminder = draft.reminderTime != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 4, offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: T.primary.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Task ${index + 1}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: T.primary)),
              ),
              const Spacer(),
              if (onRemove != null)
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, color: T.danger, size: 18),
                  onPressed: onRemove,
                  tooltip: 'Remove task',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Task name field
          TextField(
            controller: draft.textCtrl,
            decoration: const InputDecoration(
              hintText: 'Task name',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (_) => onUpdate(),
          ),
          const SizedBox(height: 10),

          // Time row: picker button only
          Row(
            children: [
              GestureDetector(
                onTap: onPickTime,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: T.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.alarm_rounded, size: 16, color: T.primary),
                      const SizedBox(width: 4),
                      Text(
                        hasReminder ? formatTOD(TimeOfDay.fromDateTime(draft.reminderTime!)) : 'Set reminder',
                        style: TextStyle(
                          fontSize: 12,
                          color: hasReminder ? T.primary : T.sub,
                          fontWeight: hasReminder ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (hasReminder) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.clear, size: 16, color: T.danger),
                  onPressed: () {
                    draft.reminderTime = null;
                    draft.startTime = null;
                    onUpdate();
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ],
          ),

          if (hasReminder) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.notifications_active_outlined, size: 13, color: T.sub),
                const SizedBox(width: 4),
                Text('Reminder at ${formatTOD(TimeOfDay.fromDateTime(draft.reminderTime!))}',
                    style: const TextStyle(fontSize: 11, color: T.sub)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class RoleTaskPage extends StatefulWidget {
  final String role;
  const RoleTaskPage({super.key, required this.role});
  @override
  State<RoleTaskPage> createState() => _RoleState();
}

class _RoleState extends State<RoleTaskPage> {

  @override
  void initState() {
    super.initState();
    taskStore.addListener(_rebuild);
  }

  @override
  void dispose() {
    taskStore.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() { if (mounted) setState(() {}); }

  List<AppTask> get _myTasks {
    final today = DateTime.now();
    return taskStore.value.where((t) =>
    t.category == widget.role &&
        t.createdAt.year  == today.year &&
        t.createdAt.month == today.month &&
        t.createdAt.day   == today.day).toList();
  }

  int get _done => _myTasks.where((t) => t.done).length;

  @override
  Widget build(BuildContext ctx) {
    final tasks = _myTasks;
    final label = widget.role[0].toUpperCase() + widget.role.substring(1);

    return Scaffold(
      appBar: AppBar(title: Text('$label Tasks')),
      body: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: T.primary,
          child: Row(children: [
            Expanded(child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: tasks.isEmpty ? 0 : _done / tasks.length,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(T.accent),
                minHeight: 10,
              ),
            )),
            const SizedBox(width: 12),
            Text('$_done/${tasks.length}',
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
        ),
        Expanded(child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: tasks.length,
          itemBuilder: (_, i) {
            final t = tasks[i];
            return Card(
              key: ValueKey(t.id),
              child: CheckboxListTile(
                activeColor: T.accent,
                value: t.done,
                onChanged: (_) => taskStore.toggle(t.id),
                title: Text(t.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        decoration:
                        t.done ? TextDecoration.lineThrough : null,
                        color: t.done ? T.sub : T.text)),
                secondary: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.star_rounded,
                        color: Colors.amber, size: 14),
                    const SizedBox(width: 2),
                    Text('${t.points}',
                        style: const TextStyle(fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber)),
                  ]),
                ),
              ),
            );
          },
        )),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  UNIFIED NOTE EDITOR PAGE
//  • Mode toggle: Text vs Checklist at top
//  • Seamless switching without data loss
// ═══════════════════════════════════════════════════════════════════════════

class UnifiedNoteEditorPage extends StatefulWidget {
  final Note? note;
  final String initialType;

  const UnifiedNoteEditorPage({
    super.key,
    this.note,
    this.initialType = 'text',
  });

  @override
  State<UnifiedNoteEditorPage> createState() => _UnifiedNoteEditorState();
}

class _UnifiedNoteEditorState extends State<UnifiedNoteEditorPage> {
  late TextEditingController _titleCtrl;
  late TextEditingController _bodyCtrl;
  late String _noteType;
  late List<ChecklistItem> _checklistItems;
  late List<TextEditingController> _checklistControllers;
  DateTime? _reminder;

  bool get _isEditing => widget.note != null;

  @override
  void initState() {
    super.initState();
    final note = widget.note;

    _titleCtrl = TextEditingController(text: note?.title ?? '');
    _bodyCtrl = TextEditingController(text: note?.body ?? '');
    _noteType = note?.type ?? widget.initialType;
    _checklistItems = note?.checklistItems.map((i) => ChecklistItem(
      id: i.id,
      title: i.title,
      isComplete: i.isComplete,
    )).toList() ?? [];
    _checklistControllers = _checklistItems
        .map((i) => TextEditingController(text: i.title))
        .toList();
    _reminder = note?.reminderTime;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    for (final ctrl in _checklistControllers) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _syncChecklistFromControllers() {
    for (int i = 0; i < _checklistItems.length && i < _checklistControllers.length; i++) {
      _checklistItems[i] = _checklistItems[i].copyWith(
        title: _checklistControllers[i].text,
      );
    }
  }

  /// Switch from text → checklist (split text into items)
  void _switchToChecklist() {
    final text = _bodyCtrl.text.trim();
    if (text.isNotEmpty) {
      final lines = text.split('\n').where((l) => l.trim().isNotEmpty);
      _checklistItems = lines.map((line) {
        String cleaned = line.trim();
        bool isComplete = false;

        if (cleaned.startsWith('✓') || cleaned.startsWith('[x]') || cleaned.startsWith('[X]')) {
          isComplete = true;
        }

        final regex = RegExp(r'^([\u2022\u2023\u25E6\u2043\u2219\u00B7\-\*✓]|\[[ xX]\])\s*');
        while (regex.hasMatch(cleaned)) {
          cleaned = cleaned.replaceFirst(regex, '');
        }

        return ChecklistItem(
          title: cleaned.trim(),
          isComplete: isComplete,
        );
      }).toList();
    }

    // Refresh controllers
    for (final ctrl in _checklistControllers) {
      ctrl.dispose();
    }
    _checklistControllers = _checklistItems
        .map((i) => TextEditingController(text: i.title))
        .toList();

    setState(() => _noteType = 'checklist');
  }

  /// Switch from checklist → text (join items into body)
  void _switchToText() {
    _syncChecklistFromControllers();
    final content = _checklistItems
        .map((item) {
          String title = item.title.trim();
          final regex = RegExp(r'^([\u2022\u2023\u25E6\u2043\u2219\u00B7\-\*✓]|\[[ xX]\])\s*');
          while (regex.hasMatch(title)) {
            title = title.replaceFirst(regex, '');
          }
          return item.isComplete ? '✓ ${title.trim()}' : title.trim();
        })
        .join('\n');
    _bodyCtrl.text = content;
    setState(() => _noteType = 'text');
  }

  Future<void> _pickReminder() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _reminder ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(minutes: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: _reminder != null
          ? TimeOfDay.fromDateTime(_reminder!)
          : TimeOfDay.now(),
    );
    if (time == null) return;

    setState(() => _reminder = DateTime(
      date.year, date.month, date.day,
      time.hour, time.minute,
    ));
  }

  void _save() {
    if (_titleCtrl.text.trim().isEmpty) {
      showSnack(context, 'Please enter a title', isError: true);
      return;
    }

    if (_noteType == 'checklist') {
      _syncChecklistFromControllers();
      if (_checklistItems.isEmpty) {
        showSnack(context, 'Add at least one checklist item', isError: true);
        return;
      }
    }

    final result = Note(
      id: _isEditing ? widget.note!.id : null,
      title: _titleCtrl.text.trim(),
      body: _noteType == 'text' ? _bodyCtrl.text.trim() : '',
      type: _noteType,
      checklistItems: _noteType == 'checklist' ? _checklistItems : [],
      reminderTime: _reminder,
      reminderRepeat: RecurrenceType.none,
      createdAt: _isEditing ? widget.note!.createdAt : null,
    );

    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Note' : 'New Note'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title field
              TextField(
                controller: _titleCtrl,
                autofocus: !_isEditing,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(hintText: 'Title'),
              ),
              const SizedBox(height: 16),

              // MODE TOGGLE
              Text('Note type',
                  style: Theme.of(ctx).textTheme.labelLarge),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _noteType == 'checklist' ? _switchToText : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: _noteType == 'text'
                              ? T.primary
                              : Colors.white,
                          border: Border.all(
                            color: T.primary.withOpacity(0.3),
                            width: _noteType == 'text' ? 2 : 0.5,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            'Text note',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: _noteType == 'text'
                                  ? Colors.white
                                  : T.text,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: _noteType == 'text' ? _switchToChecklist : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: _noteType == 'checklist'
                              ? T.accent
                              : Colors.white,
                          border: Border.all(
                            color: T.accent.withOpacity(0.3),
                            width: _noteType == 'checklist' ? 2 : 0.5,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            'Checklist',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: _noteType == 'checklist'
                                  ? Colors.white
                                  : T.text,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // CONTENT AREA
              Expanded(
                child: _noteType == 'text'
                    ? TextField(
                        controller: _bodyCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(
                          hintText: 'Start typing your note...',
                          alignLabelWithHint: true,
                          contentPadding: EdgeInsets.all(12),
                        ),
                      )
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Checklist items',
                                style: Theme.of(ctx).textTheme.labelLarge),
                            const SizedBox(height: 8),
                            ..._checklistItems.asMap().entries.map((entry) {
                              int idx = entry.key;
                              ChecklistItem item = entry.value;
                              return _buildChecklistItemTile(idx, item);
                            }).toList(),
                            const SizedBox(height: 8),
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _checklistItems.add(ChecklistItem(title: ''));
                                  _checklistControllers.add(TextEditingController(text: ''));
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.grey[300]!,
                                    style: BorderStyle.solid,
                                  ),
                                ),
                                child: const Center(
                                  child: Text(
                                    '+ Add item',
                                    style: TextStyle(color: T.sub),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 16),

              // REMINDER
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: T.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: T.primary.withOpacity(0.2)),
                ),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.alarm_rounded, color: T.primary),
                  title: Text(
                    _reminder == null ? 'Set reminder' : fmtDT(_reminder!),
                    style: TextStyle(
                      color: _reminder == null ? T.sub : T.text,
                      fontWeight: _reminder != null ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  trailing: _reminder != null
                      ? GestureDetector(
                          onTap: () => setState(() => _reminder = null),
                          child: const Icon(Icons.close, color: T.danger),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _pickReminder,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChecklistItemTile(int idx, ChecklistItem item) {
    if (idx >= _checklistControllers.length) {
      _checklistControllers.add(TextEditingController(text: item.title));
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey[50],
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              setState(() {
                _checklistItems[idx] = _checklistItems[idx].copyWith(
                  isComplete: !_checklistItems[idx].isComplete,
                );
              });
            },
            child: Icon(
              _checklistItems[idx].isComplete
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              color: _checklistItems[idx].isComplete ? T.accent : T.sub,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _checklistControllers[idx],
              onChanged: (value) {
                _checklistItems[idx] = _checklistItems[idx].copyWith(
                  title: value,
                );
              },
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Item ${idx + 1}',
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                _checklistItems.removeAt(idx);
                final removedCtrl = _checklistControllers.removeAt(idx);
                removedCtrl.dispose();
              });
            },
            child: const Icon(Icons.close, color: T.danger, size: 18),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  NOTES PAGE  — List all notes (text + checklist unified)
// ═══════════════════════════════════════════════════════════════════════════

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});
  @override
  State<NotesPage> createState() => _NotesState();
}

class _NotesState extends State<NotesPage> {

  @override
  void initState() {
    super.initState();
    noteStore.addListener(_rebuild);
  }

  @override
  void dispose() {
    noteStore.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _delete(Note n) async {
    final ok = await confirmDelete(context, 'Note');
    if (!ok) return;
    if (n.reminderTime != null) await cancelNotif(n.id.hashCode);
    await noteStore.delete(n.id);
    if (mounted) showSnack(context, 'Note deleted');
  }

  Future<void> _openEditor(Note? note) async {
    final result = await Navigator.push<Note>(
      context,
      MaterialPageRoute(
        builder: (_) => UnifiedNoteEditorPage(
          note: note,
          initialType: note?.type ?? 'text',
        ),
      ),
    );

    if (result == null) return;

    if (note != null && note.reminderTime != null) {
      await cancelNotif(note.id.hashCode);
    }

    if (note != null) {
      await noteStore.update(result);
    } else {
      await noteStore.create(result);
    }

    if (result.reminderTime != null) {
      final notifBody = result.type == 'checklist'
          ? 'Checklist Reminder'
          : 'Note Reminder';
      await scheduleNotif(
        id: result.id.hashCode,
        title: result.title,
        body: notifBody,
        at: result.reminderTime!,
        recurrenceType: RecurrenceType.none,
      );
    }

    if (mounted) {
      showSnack(
        context,
        note == null ? 'Note created' : 'Note updated',
      );
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final notes = noteStore.value;

    if (notes.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notes')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.note_add_rounded, size: 64, color: Colors.grey[300]),
              const SizedBox(height: 12),
              Text('No notes yet',
                  style: TextStyle(color: Colors.grey[400], fontSize: 16)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _openEditor(null),
                icon: const Icon(Icons.add),
                label: const Text('Create Note'),
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _openEditor(null),
          child: const Icon(Icons.add),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: notes.length,
        itemBuilder: (_, i) {
          final note = notes[i];
          final isChecklist = note.type == 'checklist';
          final checkedCount = isChecklist
              ? note.checklistItems.where((item) => item.isComplete).length
              : 0;

          return Card(
            key: ValueKey(note.id),
            child: ListTile(
              leading: Icon(
                isChecklist ? Icons.checklist_rounded : Icons.note_rounded,
                color: isChecklist ? T.accent : T.primary,
              ),
              title: Text(
                note.title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isChecklist)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '$checkedCount/${note.checklistItems.length} items completed',
                        style: const TextStyle(fontSize: 12, color: T.sub),
                      ),
                    )
                  else if (note.body.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        note.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: T.sub),
                      ),
                    ),
                  if (note.reminderTime != null) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          fmtTimeAgo(note.createdAt),
                          style: const TextStyle(fontSize: 11, color: T.sub),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: T.primary.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.alarm_rounded, size: 12, color: T.primary),
                              const SizedBox(width: 3),
                              Text(
                                fmtDT(note.reminderTime!),
                                style: const TextStyle(fontSize: 10, color: T.primary, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 6),
                    Text(
                      fmtTimeAgo(note.createdAt),
                      style: const TextStyle(fontSize: 11, color: T.sub),
                    ),
                  ],
                ],
              ),
              onTap: () => _openEditor(note),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20, color: T.sub),
                    onPressed: () => _openEditor(note),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 20, color: T.danger),
                    onPressed: () => _delete(note),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(null),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PROGRESS PAGE — SIMPLIFIED
//  • Overall points + badge
//  • Checklist progress
//  • Daily breakdown chart
//  • Recent completions
// ═══════════════════════════════════════════════════════════════════════════

class ProgressPage extends StatefulWidget {
  const ProgressPage({super.key});
  @override
  State<ProgressPage> createState() => _ProgState();
}

class _ProgState extends State<ProgressPage> {

  @override
  void initState() {
    super.initState();
    taskStore.addListener(_rebuild);
    noteStore.addListener(_rebuild);
  }

  @override
  void dispose() {
    taskStore.removeListener(_rebuild);
    noteStore.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  List<AppTask> get _allTasks => taskStore.value;
  List<AppTask> get _done     => _allTasks.where((t) => t.done).toList();
  int           get _pts      => taskStore.points;

  DateTime startOfWeek(DateTime dt) {
    return DateTime(dt.year, dt.month, dt.day).subtract(Duration(days: dt.weekday - 1));
  }

  List<Map<String, dynamic>> get _week {
    final now = DateTime.now();
    final monday = startOfWeek(now);
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return List.generate(7, (i) {
      final d = monday.add(Duration(days: i));
      final dateKey = AppTask.formatDateKey(d);

      int n = _done.where((t) =>
          !t.isRecurring &&
          t.completedAt != null &&
          t.completedAt!.year == d.year &&
          t.completedAt!.month == d.month &&
          t.completedAt!.day == d.day).length;

      n += _allTasks.where((t) => t.completedDates.contains(dateKey)).length;
      return {'day': days[i], 'n': n};
    });
  }

  Map<DateTime, List<String>> get _pastWeeksSummary {
    final now = DateTime.now();
    final curMonday = startOfWeek(now);
    final groups = <DateTime, List<String>>{};

    for (final t in _done) {
      if (!t.isRecurring && t.completedAt != null) {
        final m = startOfWeek(t.completedAt!);
        if (m.isBefore(curMonday)) {
          groups.putIfAbsent(m, () => []).add(t.text);
        }
      }
    }

    for (final t in _allTasks) {
      for (final dateStr in t.completedDates) {
        final parts = dateStr.split('-');
        if (parts.length == 3) {
          final y = int.tryParse(parts[0]);
          final m = int.tryParse(parts[1]);
          final d = int.tryParse(parts[2]);
          if (y != null && m != null && d != null) {
            final dt = DateTime(y, m, d);
            final monday = startOfWeek(dt);
            if (monday.isBefore(curMonday)) {
              groups.putIfAbsent(monday, () => []).add('${t.text} (${t.recurrenceLabel})');
            }
          }
        }
      }
    }
    return groups;
  }

  String get _badge {
    final p = _pts;
    if (p >= 500) return '🏆 Champion';
    if (p >= 200) return '🥇 Gold';
    if (p >= 100) return '🥈 Silver';
    if (p >= 50)  return '🥉 Bronze';
    return '⭐ Starter';
  }

  @override
  Widget build(BuildContext ctx) {
    final week = _week;
    final mx   = week.map((d) => d['n'] as int).fold(0, max);
    final past = _pastWeeksSummary;

    final activeDailyTasks = _allTasks.where((t) => t.isRecurring && !t.isStopped && t.recurrenceType == RecurrenceType.daily).toList();
    final dailyCompletedCount = activeDailyTasks.where((t) => t.isCompletedToday).length;
    final dailyTotal = activeDailyTasks.length;
    final dailyRatio = dailyTotal > 0 ? dailyCompletedCount / dailyTotal : 0.0;

    return Scaffold(
      appBar: AppBar(title: const Text('Progress')),
      body: RefreshIndicator(
        onRefresh: () => taskStore.load(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // POINTS HEADER
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: T.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: T.primary.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This week\'s progress',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, color: Colors.amber),
                        const SizedBox(width: 8),
                        Text('$_pts points',
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(_badge,
                        style: const TextStyle(
                            fontSize: 14, color: T.sub)),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // STAT CARDS
              Row(
                children: [
                  Expanded(child: _buildStatCard('${_allTasks.length}', 'Tasks')),
                  const SizedBox(width: 10),
                  Expanded(child: _buildStatCard('${_done.length}', 'Done')),
                  const SizedBox(width: 10),
                  Expanded(child: _buildStatCard('${noteStore.value.length}', 'Notes')),
                ],
              ),

              const SizedBox(height: 20),

              // TODAY'S RECURRING PROGRESS
              if (activeDailyTasks.isNotEmpty) ...[
                Text('Today\'s Recurring Progress',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('$dailyCompletedCount of $dailyTotal completed today',
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: dailyCompletedCount == dailyTotal ? Colors.green.withOpacity(0.12) : T.primary.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${(dailyRatio * 100).toInt()}%',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: dailyCompletedCount == dailyTotal ? Colors.green : T.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: dailyRatio,
                          minHeight: 8,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            dailyCompletedCount == dailyTotal ? Colors.green : T.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ...activeDailyTasks.map((t) {
                        final done = t.isCompletedToday;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(
                                done ? Icons.check_circle : Icons.radio_button_unchecked,
                                size: 18,
                                color: done ? Colors.green : T.sub,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  t.text,
                                  style: TextStyle(
                                    fontSize: 13,
                                    decoration: done ? TextDecoration.lineThrough : null,
                                    color: done ? T.sub : Colors.black87,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // DAILY BREAKDOWN
              Text('This Week',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
                ),
                child: SizedBox(
                  height: 140,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: week.map((d) {
                      final n   = d['n'] as int;
                      final pct = mx == 0 ? 0.0 : n / mx;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('$n',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: T.primary)),
                          const SizedBox(height: 6),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 600),
                            width: 24,
                            height: max(4.0, pct * 100),
                            decoration: BoxDecoration(
                              color: T.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(d['day'],
                              style: const TextStyle(
                                  fontSize: 11, color: T.sub)),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // RECENT COMPLETIONS
              if (_done.isNotEmpty) ...[
                Text('Recent completions',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 12),
                ..._done.reversed.take(5).map((t) => Card(
                  key: ValueKey('prog_${t.id}'),
                  child: ListTile(
                    leading: const Icon(Icons.check_circle_rounded,
                        color: T.accent),
                    title: Text(t.text,
                        style: const TextStyle(fontSize: 14)),
                    subtitle: t.completedAt != null
                        ? Text(fmtDT(t.completedAt!),
                        style: const TextStyle(
                            fontSize: 11, color: T.sub))
                        : null,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star_rounded,
                          color: Colors.amber, size: 14),
                      const SizedBox(width: 2),
                      Text('+${t.points}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.amber)),
                    ]),
                  ),
                )),
              ],

              // WEEKLY HISTORY
              if (past.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Weekly History',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 12),
                ...past.entries.map((entry) {
                  final monday = entry.key;
                  final taskTitles = entry.value;
                  final sunday = monday.add(const Duration(days: 6));
                  final dateRange = '${monday.day}/${monday.month} - ${sunday.day}/${sunday.month}';
                  
                  return Card(
                    key: ValueKey('history_${monday.millisecondsSinceEpoch}'),
                    child: ListTile(
                      leading: const Icon(Icons.history_toggle_off_rounded, color: T.primary),
                      title: Text('Week of $dateRange',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      subtitle: Text('${taskTitles.length} completions logged',
                          style: const TextStyle(fontSize: 12, color: T.sub)),
                    ),
                  );
                }).toList(),
              ],

              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(String value, String label) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(fontSize: 11, color: T.sub),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  SETTINGS PAGE
// ═══════════════════════════════════════════════════════════════════════════

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: T.danger),
          SizedBox(width: 8),
          Text('Clear All Data?'),
        ]),
        content: const Text(
            'Deletes all tasks, notes and resets your points.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: T.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    if (ok == true) {
      taskStore.value  = [];
      taskStore.points = 0;
      noteStore.value  = [];
      await Storage.saveTasks([]);
      await Storage.saveNotes([]);
      await Storage.savePoints(0);
      if (mounted) {
        showSnack(context, 'All data cleared');
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.notifications_active_rounded,
                      color: T.primary),
                  SizedBox(width: 8),
                  Text('Notifications',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ]),
                const SizedBox(height: 8),
                const Text(
                  'Make sure:\n'
                      '• Notifications enabled: Android Settings → Apps → DoIt\n'
                      '• "Alarms & Reminders" enabled for DoIt\n'
                      '• Battery optimisation disabled for DoIt',
                  style: TextStyle(
                      fontSize: 13, color: T.sub, height: 1.5),
                ),
                const SizedBox(height: 16),
                SizedBox(width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await showInstantNotif(
                        'DoIt Test 🔔',
                        'Notifications are working!',
                      );
                      if (mounted) showSnack(ctx, 'Test notification sent!');
                    },
                    icon: const Icon(Icons.notifications_rounded),
                    label: const Text('Send Test Notification'),
                  ),
                ),
              ],
            ),
          )),

          const SizedBox(height: 16),

          Card(child: ListTile(
            leading: const Icon(Icons.delete_forever_rounded,
                color: T.danger),
            title: const Text('Clear All Data',
                style: TextStyle(
                    color: T.danger, fontWeight: FontWeight.w600)),
            subtitle: const Text('Delete all tasks, notes and points',
                style: TextStyle(fontSize: 12)),
            onTap: _clearAll,
          )),

          const SizedBox(height: 32),
          Center(child: Text('DoIt v2.0',
              style: TextStyle(color: Colors.grey[400], fontSize: 13))),
        ],
      ),
    );
  }
}