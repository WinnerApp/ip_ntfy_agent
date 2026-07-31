import 'package:test/test.dart';

import 'package:ip_ntfy_agent/appwrite_service.dart';
import 'package:ip_ntfy_agent/ip_service.dart';
import 'package:ip_ntfy_agent/jenkins_service.dart';

void main() {
  test('ipToTopic replaces dots', () {
    expect(ipToTopic('10.10.48.63'), 'topic_10_10_48_63');
  });

  test('urlFromIp builds http url with Jenkins default port', () {
    expect(urlFromIp('10.10.48.63'), 'http://10.10.48.63:8080');
  });

  test('urlWithHost replaces host and keeps port/path', () {
    expect(
      urlWithHost('http://10.10.48.1:8080/jenkins/', '10.10.48.63'),
      'http://10.10.48.63:8080/jenkins/',
    );
  });

  test('urlWithHost falls back when url missing', () {
    expect(urlWithHost(null, '10.10.48.63'), 'http://10.10.48.63:8080');
  });

  test('urlWithHost adds default port when missing', () {
    expect(
      urlWithHost('http://10.10.48.1/', '10.10.48.63'),
      'http://10.10.48.63:8080/',
    );
  });

  test('hotUpdateZipUrl matches legacy Jenkins workspace path', () {
    expect(
      JenkinsService.hotUpdateZipUrl(
        jenkinsUrl: 'http://10.10.48.63:8080/',
        buildNumber: '123',
        platform: 'iOS',
      ),
      'http://10.10.48.63:8080/job/build_unity_hot_asset/ws/HotUpdate/123/IOS'
          '/UploadAssets/*zip*/UploadAssets.zip',
    );
    expect(
      JenkinsService.hotUpdateZipUrl(
        jenkinsUrl: 'http://10.10.48.63',
        buildNumber: '123',
        platform: 'iOS',
      ),
      'http://10.10.48.63:8080/job/build_unity_hot_asset/ws/HotUpdate/123/IOS'
          '/UploadAssets/*zip*/UploadAssets.zip',
    );
    expect(
      JenkinsService.artifactPlatformDir('HarmonyOS'),
      'Harmony',
    );
  });

  test('localJenkinsBase uses 127.0.0.1 and doc port (default 8080)', () {
    expect(
      JenkinsService.localJenkinsBase('http://10.10.48.63'),
      'http://127.0.0.1:8080',
    );
    expect(
      JenkinsService.localJenkinsBase('http://10.10.48.63:8080/'),
      'http://127.0.0.1:8080',
    );
    expect(
      JenkinsService.localJenkinsBase('http://10.10.48.63:9090'),
      'http://127.0.0.1:9090',
    );
    expect(
      JenkinsService.hotUpdateZipUrl(
        jenkinsUrl: JenkinsService.localJenkinsBase('http://10.10.48.63'),
        buildNumber: '3047',
        platform: 'iOS',
      ),
      'http://127.0.0.1:8080/job/build_unity_hot_asset/ws/HotUpdate/3047/IOS'
          '/UploadAssets/*zip*/UploadAssets.zip',
    );
  });

  test('storageBuildId prefixes apk to avoid zip collision', () {
    expect(
      AppwriteService.storageBuildId('123', kind: 'zip'),
      '123',
    );
    expect(
      AppwriteService.storageBuildId('123', kind: 'apk'),
      'apk:123',
    );
  });
}
