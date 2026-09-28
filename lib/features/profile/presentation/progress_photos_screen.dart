import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/media/app_media_store.dart';
import '../../../data/database_helper.dart';
import '../../../data/drift_database.dart' as db;
import '../../today/domain/daily_record_models.dart';
import '../data/progress_photo_repository.dart';
import '../../today/data/day_lock_repository.dart';

class ProgressPhotosScreen extends StatefulWidget {
  final DateTime? initialDate;
  final ProgressPhotoRepository? repository;

  const ProgressPhotosScreen({super.key, this.initialDate, this.repository});

  @override
  State<ProgressPhotosScreen> createState() => _ProgressPhotosScreenState();
}

class _ProgressPhotosScreenState extends State<ProgressPhotosScreen> {
  late final ProgressPhotoRepository _repository = widget.repository ??
      ProgressPhotoRepository(DatabaseHelper.instance.dbInstance);
  late DateTime _date = localDay(widget.initialDate ?? DateTime.now());
  late Stream<List<db.ProgressPhoto>> _photos = _repository.watchDay(_date);
  bool _saving = false;

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
        context: context,
        initialDate: _date,
        firstDate: DateTime(2000),
        lastDate: DateTime.now());
    if (picked == null) return;
    setState(() {
      _date = localDay(picked);
      _photos = _repository.watchDay(_date);
    });
  }

  Future<void> _addPhoto() async {
    try {
      await DayLockRepository(_repository.database).requireUnlocked(_date);
    } on DayLockedException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return;
    }
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null) return;
    setState(() => _saving = true);
    try {
      await _repository.add(File(image.path), _date);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error is DayLockedException
                ? error.toString()
                : 'Could not save photo. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editNote(db.ProgressPhoto photo) async {
    final controller = TextEditingController(text: photo.note ?? '');
    final saved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Photo note'),
              content: TextField(
                  controller: controller,
                  maxLines: 3,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Optional note')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Save')),
              ],
            ));
    final note = controller.text;
    controller.dispose();
    if (saved == true) {
      try {
        await _repository.updateNote(photo.id, note);
      } on DayLockedException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }
  }

  Future<void> _deletePhoto(db.ProgressPhoto photo) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Delete progress photo?'),
              content:
                  const Text('This photo will be removed from this device.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete')),
              ],
            ));
    if (confirmed == true) {
      try {
        await _repository.delete(photo.id);
      } on DayLockedException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    }
  }

  Future<void> _viewPhoto(db.ProgressPhoto photo) async {
    final file = await AppMediaStore.instance.resolve(photo.mediaPath);
    if (!mounted) return;
    final exists = file != null && await file.exists();
    if (!mounted) return;
    if (file == null || !exists) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo file is unavailable.')));
      return;
    }
    if (!mounted) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => Scaffold(
                  appBar: AppBar(title: Text(DateFormat.yMMMd().format(_date))),
                  body: Column(children: [
                    Expanded(
                        child: Center(
                            child: InteractiveViewer(child: Image.file(file)))),
                    if (photo.note?.isNotEmpty == true)
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(photo.note!)),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      TextButton(
                          onPressed: () async {
                            await _editNote(photo);
                            if (mounted) Navigator.pop(context);
                          },
                          child: const Text('Edit note')),
                      TextButton(
                          onPressed: () async {
                            await _deletePhoto(photo);
                            if (mounted) Navigator.pop(context);
                          },
                          child: const Text('Delete')),
                    ]),
                  ]),
                )));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Progress photos')),
        body: StreamBuilder<List<db.ProgressPhoto>>(
          stream: _photos,
          builder: (context, snapshot) {
            final photos = snapshot.data ?? const <db.ProgressPhoto>[];
            return ListView(padding: const EdgeInsets.all(16), children: [
              OutlinedButton.icon(
                  onPressed: _selectDate,
                  icon: const Icon(Icons.calendar_today),
                  label: Text(DateFormat.yMMMd().format(_date))),
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: _saving ? null : _addPhoto,
                  icon: const Icon(Icons.add_a_photo),
                  label: Text(_saving ? 'Saving…' : 'Add photo')),
              const SizedBox(height: 16),
              if (photos.isEmpty) const Text('No photos for this date'),
              for (final photo in photos)
                ListTile(
                  key: ValueKey('progress-photo-${photo.id}'),
                  title: Text(photo.note?.isNotEmpty == true
                      ? photo.note!
                      : 'Progress photo'),
                  subtitle: Text(photo.localDate),
                  leading: FutureBuilder<File?>(
                      future: AppMediaStore.instance.resolve(photo.mediaPath),
                      builder: (context, file) => file.data == null
                          ? const Icon(Icons.photo)
                          : Image.file(file.data!,
                              width: 54,
                              height: 54,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.broken_image))),
                  onTap: () => _viewPhoto(photo),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) => action == 'note'
                        ? _editNote(photo)
                        : _deletePhoto(photo),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'note', child: Text('Edit note')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
            ]);
          },
        ),
      );
}
