import 'dart:async';
import 'dart:io';

import 'package:conduit/features/chat/widgets/composer_focus_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:riverpod/riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';

import '../features/chat/services/file_attachment_service.dart';

import 'package:conduit_core/features/chat/voice_call/voice_call_eligibility.dart';

import '../l10n/app_localizations.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'widget_omni_routing.dart';
import '../features/chat/voice_call/presentation/voice_call_launcher.dart';
import '../features/notifications/providers/notification_socket_listener.dart';
import 'package:conduit_core/features/chat/omni/omni_chat.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/providers/app_providers.dart';
import '../core/services/media_upload_controller.dart';
import '../shared/services/navigation_service.dart';

part 'home_widget_service.g.dart';

/// Widget action identifiers matching native widget implementations.
class WidgetActions {
  static const String newChat = 'new_chat';
  static const String actions = 'actions';
  static const String mic = 'mic';
  static const String camera = 'camera';
  static const String photos = 'photos';
  static const String clipboard = 'clipboard';
}

/// App group identifier for iOS widget data sharing.
const String _releaseAppGroupId = 'group.app.cogwheel.conduit';
const String _debugAppGroupId = 'group.app.cogwheel.conduit.x2662v5dt2.debug';

String get _appGroupId => kReleaseMode ? _releaseAppGroupId : _debugAppGroupId;

/// Android widget provider class name.
const String _qualifiedAndroidWidgetName =
    'app.cogwheel.conduit.ConduitWidgetProvider';

/// iOS widget kind identifier.
const String _iOSWidgetKind = 'ConduitWidget';

/// Handles home screen widget interactions for Android and iOS.
///
/// The widget provides quick actions:
/// - New Chat: Start a fresh conversation
/// - Camera: Take a photo and attach to chat
/// - Photos: Pick from gallery and attach to chat
/// - Clipboard: Paste clipboard content as prompt
@Riverpod(keepAlive: true)
class HomeWidgetCoordinator extends _$HomeWidgetCoordinator {
  StreamSubscription<Uri?>? _widgetClickSubscription;
  Uri? _pendingWidgetAction;

  @override
  FutureOr<void> build() async {
    if (kIsWeb) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;

    await _initialize();

    ref.onDispose(() {
      _widgetClickSubscription?.cancel();
    });
  }

  Future<void> _initialize() async {
    try {
      // Set app group for iOS data sharing
      if (Platform.isIOS) {
        await HomeWidget.setAppGroupId(_appGroupId);
      }

      // Handle widget clicks
      _widgetClickSubscription = HomeWidget.widgetClicked.listen(
        _handleWidgetClick,
        onError: (error) {
          DebugLogger.error(
            'home-widget-stream',
            scope: 'widget',
            error: error,
          );
        },
      );

      // Check for initial launch from widget
      final initialUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (initialUri != null) {
        DebugLogger.log(
          'Widget: Initial launch URI: $initialUri',
          scope: 'widget',
        );
        // Store for later processing once app is ready
        _pendingWidgetAction = initialUri;
        // Try to process after a delay to allow router to initialize
        _processInitialWidgetAction();
      }

      DebugLogger.log('Home widget service initialized', scope: 'widget');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-init',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Process initial widget action after ensuring router and chat are ready.
  Future<void> _processInitialWidgetAction() async {
    if (_pendingWidgetAction == null) return;

    // Wait for router to be attached first
    for (var i = 0; i < 50; i++) {
      // Try for up to 5 seconds
      await Future<void>.delayed(const Duration(milliseconds: 100));

      if (NavigationService.currentRoute != null) {
        DebugLogger.log(
          'Widget: Router ready, waiting for chat readiness',
          scope: 'widget',
        );
        break;
      }
    }

    if (NavigationService.currentRoute == null) {
      DebugLogger.log(
        'Widget: Timeout waiting for router, clearing pending action',
        scope: 'widget',
      );
      _pendingWidgetAction = null;
      return;
    }

    // Check if action was already processed by stream handler while waiting
    if (_pendingWidgetAction == null) return;

    final pendingUri = _pendingWidgetAction;
    if (pendingUri != null &&
        homeWidgetVoiceActionCanDispatch(
          pendingUri,
          canBypassOpenWebUiAuth: voiceCallCanResolveWithoutOpenWebUiAuth(ref),
        )) {
      _pendingWidgetAction = null;
      await _handleWidgetClick(pendingUri);
      return;
    }

    // Non-voice actions wait until chat is reachable.
    for (var i = 0; i < 300; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      if (!ref.mounted) {
        DebugLogger.log(
          'Widget: Provider disposed while waiting for chat readiness',
          scope: 'widget',
        );
        _pendingWidgetAction = null;
        return;
      }

      final pendingUri = _pendingWidgetAction;
      if (pendingUri != null &&
          homeWidgetVoiceActionCanDispatch(
            pendingUri,
            canBypassOpenWebUiAuth: voiceCallCanResolveWithoutOpenWebUiAuth(
              ref,
            ),
          )) {
        _pendingWidgetAction = null;
        await _handleWidgetClick(pendingUri);
        return;
      }

      // Accountless Direct/Hermes installs are ready without an Open WebUI
      // session; otherwise keep waiting because the user might be signing in.
      if (ref.read(chatEntryReadyProvider)) {
        DebugLogger.log(
          'Widget: Chat ready, processing pending action',
          scope: 'widget',
        );
        final uri = _pendingWidgetAction;
        _pendingWidgetAction = null;
        await _handleWidgetClick(uri);
        return;
      }
    }

    DebugLogger.log(
      'Widget: Timeout waiting for chat readiness, clearing pending action',
      scope: 'widget',
    );
    _pendingWidgetAction = null;
  }

  Future<void> _handleWidgetClick(Uri? uri) async {
    if (uri == null) return;

    // If router isn't ready yet, store for later
    if (NavigationService.currentRoute == null) {
      DebugLogger.log(
        'Widget: Router not ready, storing action for later',
        scope: 'widget',
      );
      _pendingWidgetAction = uri;
      _processInitialWidgetAction();
      return;
    }

    final action = museyWidgetActionOf(uri);
    DebugLogger.log('Widget action: ${action.name}', scope: 'widget');
    // The M and the empty background: the app is already open as it was.
    // No Omni, no menu, no voice, no composer action, no chat switch.
    if (!museyWidgetActionUsesOmni(action)) return;
    await _waitForNavigation();

    // Everything lands in the Omni chat. When its id is not known yet the app
    // is simply opened (no new chat, no error).
    final omniId = await openOmniForWidget(
      resolveId: _omniChatId,
      open: (id) => openChatById(ref, id),
    );
    if (omniId == null) {
      DebugLogger.log('Widget: Omni unknown, opening app', scope: 'widget');
      await NavigationService.navigateToChat();
      return;
    }
    final inOmni = await waitForOpenChat(
      chatId: omniId,
      currentId: () =>
          ref.mounted ? ref.read(activeConversationProvider)?.id : null,
    );
    if (!ref.mounted) return;
    if (!inOmni) {
      DebugLogger.log('Widget: Omni did not open in time', scope: 'widget');
      return;
    }

    switch (action) {
      case MuseyWidgetAction.actions:
        ref
            .read(museyMenuIntentProvider.notifier)
            .request(actionId: museyWidgetActionIdOf(uri));
      case MuseyWidgetAction.voice:
        await _handleMic();
      case MuseyWidgetAction.camera:
        await _handleImage(camera: true);
      case MuseyWidgetAction.photos:
        await _handleImage(camera: false);
      case MuseyWidgetAction.clipboard:
        await _handleClipboard();
      case MuseyWidgetAction.open:
        break;
    }
  }

  /// The stored Omni chat id (or one the app already resolved). Nothing is
  /// created here: with the Omni setting off or no id yet this is null.
  Future<String?> _omniChatId() async {
    if (!ref.read(appSettingsProvider).omniChatEnabled) return null;
    final stored = storedOmniChatId();
    if (stored != null && stored.isNotEmpty) return stored;
    final id = ref.read(omniChatProvider).value?.id;
    return id == null || id.isEmpty ? null : id;
  }

  /// Voice mode in the open (Omni) chat.
  Future<void> _handleMic() async {
    DebugLogger.log('Widget: Starting voice call in Omni', scope: 'widget');
    try {
      await ref
          .read(voiceCallLauncherProvider)
          .launch(startNewConversation: false);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-mic',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
      final context = NavigationService.context;
      if (context == null || !context.mounted) return;
      final message = error is StateError
          ? error.message.toString()
          : AppLocalizations.of(context)?.errorMessage ??
                'Unable to start a voice call.';
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// A photo (camera or library) into the Omni composer.
  Future<void> _handleImage({required bool camera}) async {
    DebugLogger.log('Widget: Picking image (camera: $camera)', scope: 'widget');
    // Attachments route through the selected model's transport.
    if (!await waitForChatEntryReady(ref, requireModel: true)) {
      DebugLogger.log('Widget: Chat not ready for image', scope: 'widget');
      return;
    }
    try {
      final picker = ImagePicker();
      final List<XFile> images;
      if (camera) {
        final one = await picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 85,
        );
        images = one == null ? const [] : [one];
      } else {
        images = await picker.pickMultiImage(imageQuality: 85);
      }
      if (images.isNotEmpty) {
        for (final image in images) {
          _attachFile(File(image.path));
        }
        _focusComposer();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-image',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// The clipboard text into the Omni composer (not sent).
  Future<void> _handleClipboard() async {
    DebugLogger.log('Widget: Pasting from clipboard', scope: 'widget');
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboardData?.text?.trim();
      if (text != null && text.isNotEmpty && ref.mounted) {
        ref.read(prefilledInputTextProvider.notifier).set(text);
      }
      _focusComposer();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-clipboard',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Wait for the navigation system to be ready.
  Future<void> _waitForNavigation() async {
    // Wait for bindings to be initialized
    WidgetsBinding.instance.addPostFrameCallback((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  void _attachFile(File file) {
    if (!ref.mounted) return;

    // Warm the attachment service
    ref.read(fileAttachmentServiceProvider);
    final notifier = ref.read(attachedFilesProvider.notifier);
    final mediaUpload = ref.read(mediaUploadControllerProvider);

    final attachment = LocalAttachment(
      file: file,
      displayName: path.basename(file.path),
    );

    notifier.addFiles([attachment]);

    // Fire the upload concurrently: upload() blocks until terminal status, so
    // awaiting it here would serialize a multi-photo pick (each upload waiting
    // for the previous one to finish).
    unawaited(() async {
      try {
        await mediaUpload.upload(
          filePath: file.path,
          fileName: attachment.displayName,
          fileSize: await file.length(),
        );
      } catch (error, stackTrace) {
        DebugLogger.error(
          'home-widget-upload',
          scope: 'widget',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }());
  }

  /// Bumps [inputFocusTriggerProvider] once so the composer takes focus after
  /// attachments are added — independent of when the uploads finish.
  void _focusComposer() {
    if (!ref.mounted) return;
    ref.read(composerFocusIntentProvider.notifier).request();
  }

  /// Update widget data displayed on home screen.
  ///
  /// Call this when app state changes that should be reflected in widget.
  Future<void> updateWidgetData() async {
    if (kIsWeb) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;

    try {
      // For now, we just trigger a widget update
      // In the future, we could pass data like recent conversations

      if (Platform.isAndroid) {
        await HomeWidget.updateWidget(
          qualifiedAndroidName: _qualifiedAndroidWidgetName,
        );
      } else if (Platform.isIOS) {
        await HomeWidget.updateWidget(iOSName: _iOSWidgetKind);
      }

      DebugLogger.log('Widget data updated', scope: 'widget');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'home-widget-update',
        scope: 'widget',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

@visibleForTesting
String? homeWidgetActionOf(Uri uri) =>
    uri.host.isNotEmpty ? uri.host : uri.pathSegments.firstOrNull;

@visibleForTesting
bool homeWidgetVoiceActionCanDispatch(
  Uri uri, {
  required bool canBypassOpenWebUiAuth,
}) {
  return homeWidgetActionOf(uri) == WidgetActions.mic && canBypassOpenWebUiAuth;
}

/// Provider to trigger home widget initialization at app startup.
final homeWidgetInitializerProvider = Provider<void>((ref) {
  if (kIsWeb) return;
  if (!Platform.isIOS && !Platform.isAndroid) return;

  // Initialize the coordinator which sets up widget click handling
  ref.watch(homeWidgetCoordinatorProvider);
});
