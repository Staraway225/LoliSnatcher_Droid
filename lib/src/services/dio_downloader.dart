import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:lolisnatcher/src/handlers/settings_handler.dart';
import 'package:lolisnatcher/src/services/image_writer.dart';
import 'package:lolisnatcher/src/utils/dio_network.dart';
import 'package:lolisnatcher/src/utils/logger.dart';
import 'package:lolisnatcher/src/utils/tools.dart';

class DioDownloader {
  DioDownloader(
    this.url, {
    this.headers = const <String, dynamic>{},
    this.cancelToken,
    this.onProgress,
    this.onEvent,
    this.onError,
    this.onDone,
    this.onDoneFile,
    this.cacheEnabled = false,
    this.cacheFolder = 'other',
    this.timeoutDuration,
    this.fileNameExtras = '',
    this.withLogging,
  });

  final String url;
  final Map<String, dynamic>? headers;
  final CancelToken? cancelToken;
  final void Function(int, int)? onProgress;
  final void Function(String, dynamic)? onEvent;
  final void Function(Exception)? onError;
  final void Function(Uint8List, String)? onDone;
  final void Function(File)? onDoneFile;
  final bool cacheEnabled;
  final String cacheFolder;
  final Duration? timeoutDuration;
  final String fileNameExtras;

  /// Whether to attach the HTTP inspector interceptors to this download.
  ///
  /// Defaults to the `useImageLogging` debug toggle, mirroring
  /// `CustomNetworkImage`. This matters a great deal: these requests use
  /// `ResponseType.bytes`, and Alice retains `response.data` forever while
  /// computing its size via `utf8.encode(data.toString())` -- for a 50MB video
  /// that is a ~200MB string plus a ~200MB encode, thrown away to get an int.
  final bool? withLogging;

  bool get _skipLogging => !(withLogging ?? SettingsHandler.instance.useImageLogging.value);

  Dio? currentClient;

  void dispose() {
    currentClient?.close(force: true);
    currentClient = null;
  }

  bool isRedirectBroken(Response response) {
    // TODO add checks for sankaku outdated links and others
    return false;
  }

  Future<Map<String, dynamic>> getHeaders() async {
    final Map<String, dynamic> resultHeaders = {...?headers};
    final String cookieString = await Tools.getCookies(url);
    if (cookieString.isNotEmpty) {
      resultHeaders['Cookie'] = cookieString;
    }
    return resultHeaders;
  }

  Future<void> runRequest() async {
    final ImageWriter imageWriter = ImageWriter();
    try {
      final String resolved = Uri.base.resolve(url).toString();

      final String? filePath = await imageWriter.getCachePath(
        resolved,
        cacheFolder,
        clearName: cacheFolder != 'favicons',
        fileNameExtras: fileNameExtras,
      );
      if (filePath != null) {
        // read from cache
        final File file = File(filePath);
        final int fileSize = await file.length();
        onEvent?.call('isFromCache', null);
        onProgress?.call(fileSize, fileSize);
        onEvent?.call('loaded', null);

        if (onDoneFile != null) {
          onDoneFile?.call(file);
          dispose();
        } else if (onDone != null) {
          onDone?.call(await file.readAsBytes(), url);
          dispose();
        }
        return;
      }
    } catch (e, s) {
      Logger.Inst().log(
        'Error getting from cache $url :: $e',
        runtimeType.toString(),
        'runRequest',
        LogTypes.imageLoadingError,
        s: s,
      );
      if (e is Exception) {
        onError?.call(e);
      } else {
        //
      }
      // dispose();
    }

    try {
      final String resolved = Uri.base.resolve(url).toString();
      // load from network and cache if enabled
      onEvent?.call('isFromNetwork', null);
      currentClient = DioNetwork.getClient(skipLogging: _skipLogging);
      final Response response = await currentClient!.get(
        resolved,
        options: Options(
          responseType: ResponseType.bytes,
          headers: await getHeaders(),
          sendTimeout: timeoutDuration,
          receiveTimeout: timeoutDuration,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );
      currentClient!.close();

      if (response.isRedirect == true && isRedirectBroken(response)) {
        throw DioLoadException(
          url: response.realUri.toString(),
          message: 'Image was redirected to a broken link, url should be: $resolved',
        );
      }

      if (Tools.isGoodResponse(response) == false) {
        throw DioLoadException(url: resolved, statusCode: response.statusCode);
      }

      if (response.data == null || response.data.lengthInBytes == 0) {
        throw DioLoadException(url: resolved, message: 'File did not load');
      }

      File? tempFile;
      if (cacheEnabled) {
        tempFile = await imageWriter.writeCacheFromBytes(
          resolved,
          response.data as Uint8List,
          cacheFolder,
          clearName: cacheFolder != 'favicons',
          fileNameExtras: fileNameExtras,
        );
        if (tempFile != null) {
          // onEvent?.call('isFromCache');
        }
      }

      onEvent?.call('loaded', null);
      if (onDoneFile != null && tempFile != null) {
        onDoneFile?.call(tempFile);
        dispose();
      } else if (onDone != null) {
        onDone?.call(response.data as Uint8List, url);
        dispose();
      }
      return;
    } catch (e, s) {
      final bool isCancelError = e is DioException && CancelToken.isCancel(e);
      if (!isCancelError) {
        Logger.Inst().log(
          'Error downloading $url :: $e',
          runtimeType.toString(),
          'runRequest',
          LogTypes.imageLoadingError,
          s: s,
        );
      }
      if (e is Exception) {
        onError?.call(e);
      } else {
        //
      }
      dispose();
    }
  }

  Future<void> runRequestDownload() async {
    final ImageWriter imageWriter = ImageWriter();
    try {
      final String resolved = Uri.base.resolve(url).toString();

      final String? filePath = await imageWriter.getCachePath(
        resolved,
        cacheFolder,
        clearName: cacheFolder != 'favicons',
        fileNameExtras: fileNameExtras,
      );
      if (filePath != null) {
        // read from cache
        final File file = File(filePath);
        final int fileSize = await file.length();
        onEvent?.call('isFromCache', null);
        onProgress?.call(fileSize, fileSize);
        onEvent?.call('loaded', null);

        if (onDoneFile != null) {
          onDoneFile?.call(file);
          dispose();
        }
        return;
      }
    } catch (e, s) {
      Logger.Inst().log(
        'Error getting from cache $url :: $e',
        runtimeType.toString(),
        'runRequest',
        LogTypes.imageLoadingError,
        s: s,
      );
      if (e is Exception) {
        onError?.call(e);
      } else {
        //
      }
      // dispose();
    }

    try {
      final String resolved = Uri.base.resolve(url).toString();
      // load from network and cache if enabled
      onEvent?.call('isFromNetwork', null);
      currentClient = DioNetwork.getClient(skipLogging: _skipLogging);
      final Response response = await currentClient!.download(
        resolved,
        await imageWriter.getCachePathString(
          resolved,
          cacheFolder,
          clearName: cacheFolder != 'favicons',
          fileNameExtras: fileNameExtras,
        ),
        options: Options(headers: await getHeaders(), sendTimeout: timeoutDuration, receiveTimeout: timeoutDuration),
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        deleteOnError: true,
      );
      currentClient!.close();

      if (response.isRedirect == true && isRedirectBroken(response)) {
        throw DioLoadException(
          url: response.realUri.toString(),
          message: 'Image was redirected to a broken link, url should be: $resolved',
        );
      }

      if (Tools.isGoodResponse(response) == false) {
        throw DioLoadException(url: resolved, statusCode: response.statusCode);
      }

      File? tempFile;
      if (cacheEnabled) {
        final String? tempFilePath = await imageWriter.getCachePath(
          resolved,
          cacheFolder,
          clearName: cacheFolder != 'favicons',
          fileNameExtras: fileNameExtras,
        );
        if (tempFilePath != null) {
          tempFile = File(tempFilePath);
          // onEvent?.call('isFromCache');
        }
      }

      onEvent?.call('loaded', null);
      if (onDoneFile != null && tempFile != null && await tempFile.exists()) {
        onDoneFile?.call(tempFile);
        dispose();
      }
      return;
    } catch (e, s) {
      final bool isCancelError = e is DioException && CancelToken.isCancel(e);
      if (!isCancelError) {
        Logger.Inst().log(
          'Error downloading $url :: $e',
          runtimeType.toString(),
          'runRequest',
          LogTypes.imageLoadingError,
          s: s,
        );
      }
      if (e is Exception) {
        onError?.call(e);
      } else {
        //
      }
      dispose();
    }
  }

  // get only the file size
  Future<void> runRequestSize() async {
    try {
      final String resolved = Uri.base.resolve(url).toString();

      currentClient = DioNetwork.getClient(skipLogging: _skipLogging);
      final Response response = await currentClient!.head(
        resolved,
        options: Options(
          responseType: ResponseType.bytes,
          headers: await getHeaders(),
          sendTimeout: timeoutDuration,
          receiveTimeout: timeoutDuration,
        ),
        cancelToken: cancelToken,
      );
      currentClient!.close();

      // print('response size: ${response.headers['content-length']}');

      if (response.isRedirect == true && isRedirectBroken(response)) {
        throw DioLoadException(
          url: response.realUri.toString(),
          message: 'Image was redirected to a broken link, url should be: $resolved',
        );
      }

      if (Tools.isGoodResponse(response) == false) {
        throw DioLoadException(url: resolved, statusCode: response.statusCode);
      }

      onEvent?.call('size', int.tryParse(response.headers['content-length']?.first ?? '') ?? 0);
      dispose();
      return;
    } catch (e, s) {
      final bool isCancelError = e is DioException && CancelToken.isCancel(e);
      if (!isCancelError) {
        Logger.Inst().log(
          'Error downloading $url :: $e',
          runtimeType.toString(),
          'runRequestSize',
          LogTypes.imageLoadingError,
          s: s,
        );
      }
      if (e is Exception) {
        onError?.call(e);
      } else {
        //
      }
      dispose();
    }
  }
}

class DioLoadException implements Exception {
  DioLoadException({
    required this.url,
    this.statusCode,
    this.message,
  });

  final int? statusCode;
  final String? message;
  final String url;

  @override
  String toString() => 'Dio Request failed, statusCode: $statusCode, url: $url, msg: $message';

  String toStringShort() => '${statusCode ?? message ?? 'Error'}';
}
