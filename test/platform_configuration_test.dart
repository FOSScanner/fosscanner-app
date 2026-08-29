import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<String> _activeLines(String source) =>
    source.split('\n').where((line) => !line.trimLeft().startsWith('#'));

String _activeSource(String source) => _activeLines(source).join('\n');

bool _hasActiveLine(String source, RegExp pattern) =>
    _activeLines(source).any(pattern.hasMatch);

Set<String> _assignmentValues(String source, String key) {
  final assignment = RegExp(
    '^\\s*${RegExp.escape(key)}\\s*=\\s*([^;]+);?\\s*\$',
  );
  return {
    for (final line in _activeLines(source))
      if (assignment.firstMatch(line) case final match?) match.group(1)!.trim(),
  };
}

final class _XcodeBuildConfiguration {
  const _XcodeBuildConfiguration(this.name, this.settings);

  final String name;
  final String settings;
}

List<_XcodeBuildConfiguration> _xcodeBuildConfigurations(String source) =>
    RegExp(
      r'isa = XCBuildConfiguration;[\s\S]*?buildSettings = \{([\s\S]*?)\};\s*name = ([^;]+);',
    ).allMatches(source).map((match) {
      return _XcodeBuildConfiguration(
        match.group(2)!.replaceAll('"', '').trim(),
        match.group(1)!,
      );
    }).toList();

void _expectXcodeBundleIds({
  required String path,
  required String targetSetting,
  required String bundleId,
}) {
  final configurations = _xcodeBuildConfigurations(
    File(path).readAsStringSync(),
  ).where((configuration) => configuration.settings.contains(targetSetting));
  expect(
    configurations.map((configuration) => configuration.name).toSet(),
    containsAll({'Debug', 'Profile', 'Release'}),
    reason: '$path: configurations for $targetSetting',
  );
  for (final configuration in configurations) {
    expect(
      _assignmentValues(configuration.settings, 'PRODUCT_BUNDLE_IDENTIFIER'),
      equals({bundleId}),
      reason: '$path: ${configuration.name} for $targetSetting',
    );
  }
}

List<String> _yamlListValues(String source, String key) {
  final lines = source.split('\n');
  final values = <String>[];

  for (var index = 0; index < lines.length; index++) {
    final keyMatch = RegExp(
      '^(\\s*)${RegExp.escape(key)}:\\s*\$',
    ).firstMatch(lines[index]);
    if (keyMatch == null) continue;

    final keyIndent = keyMatch.group(1)!.length;
    for (index++; index < lines.length; index++) {
      final line = lines[index];
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final indent = line.length - line.trimLeft().length;
      if (indent <= keyIndent) {
        index--;
        break;
      }
      final item = RegExp(
        r'''^\s*-\s*['"]?([^'"#]+?)['"]?\s*(?:#.*)?$''',
      ).firstMatch(line);
      if (item != null) values.add(item.group(1)!.trim());
    }
  }

  return values;
}

final class _WorkflowStep {
  const _WorkflowStep(this.source);

  final String source;

  String? get action {
    final match = RegExp(
      r'^\s*(?:-\s*)?uses:\s*([^@\s]+)@',
      multiLine: true,
    ).firstMatch(source);
    return match?.group(1);
  }

  String? get run {
    final lines = source.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final match = RegExp(
        r'^(\s*)(?:-\s+)?run:\s*(.*)$',
      ).firstMatch(lines[index]);
      if (match == null) continue;

      final value = match.group(2)!.trim();
      if (value != '|' && value != '>') return value;

      final runIndent = match.group(1)!.length;
      var commandIndent = -1;
      final command = <String>[];
      for (index++; index < lines.length; index++) {
        final line = lines[index];
        if (line.trim().isEmpty) {
          if (commandIndent >= 0) command.add('');
          continue;
        }
        final indent = line.length - line.trimLeft().length;
        if (indent <= runIndent ||
            (commandIndent >= 0 && indent < commandIndent)) {
          break;
        }
        commandIndent = commandIndent < 0 ? indent : commandIndent;
        command.add(line.substring(commandIndent));
      }
      return _activeLines(command.join('\n')).join('\n').trim();
    }
    return null;
  }
}

Iterable<String> _workflowRunCommands(String source) =>
    _workflowSteps(source).map((step) => step.run).whereType<String>();

List<_WorkflowStep> _workflowSteps(String source) {
  final lines = source.split('\n');
  final steps = <_WorkflowStep>[];

  for (var index = 0; index < lines.length; index++) {
    final start = RegExp(
      r'^(\s*)-\s+(?:name|uses|run):',
    ).firstMatch(lines[index]);
    if (start == null) continue;

    final indent = start.group(1)!.length;
    var end = index + 1;
    while (end < lines.length) {
      final next = RegExp(
        r'^(\s*)-\s+(?:name|uses|run):',
      ).firstMatch(lines[end]);
      if (next != null && next.group(1)!.length == indent) break;
      if (lines[end].trim().isNotEmpty) {
        final nextIndent = lines[end].length - lines[end].trimLeft().length;
        if (nextIndent < indent) break;
      }
      end++;
    }
    steps.add(_WorkflowStep(lines.sublist(index, end).join('\n')));
    index = end - 1;
  }

  return steps;
}

final class _WorkflowJob {
  const _WorkflowJob(this.name, this.source);

  final String name;
  final String source;
}

Map<String, _WorkflowJob> _workflowJobs(String source) {
  final lines = source.split('\n');
  final jobs = <String, _WorkflowJob>{};
  final jobsIndex = lines.indexWhere((line) => line.trim() == 'jobs:');
  if (jobsIndex < 0) return jobs;

  for (var index = jobsIndex + 1; index < lines.length; index++) {
    final jobStart = RegExp(
      r'^  ([a-zA-Z0-9_-]+):\s*$',
    ).firstMatch(lines[index]);
    if (jobStart == null) continue;

    final name = jobStart.group(1)!;
    var end = index + 1;
    while (end < lines.length &&
        RegExp(r'^  [a-zA-Z0-9_-]+:\s*$').firstMatch(lines[end]) == null) {
      end++;
    }
    jobs[name] = _WorkflowJob(name, lines.sublist(index, end).join('\n'));
    index = end - 1;
  }

  return jobs;
}

String _runner(_WorkflowJob job) => RegExp(
  r'^\s+runs-on:\s*([^\s#]+)',
  multiLine: true,
).firstMatch(job.source)!.group(1)!;

void main() {
  test('Android excludes app-private drafts from OS backup', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(
      manifest,
      matches(
        RegExp(
          r'<application[\s\S]*?android:allowBackup="false"',
          caseSensitive: false,
        ),
      ),
    );
  });

  test('native drafts use the OS-managed application cache', () {
    final source = File(
      'lib/services/draft_store_native.dart',
    ).readAsStringSync();

    expect(source, contains('getApplicationCacheDirectory()'));
    expect(source, isNot(contains('getApplicationSupportDirectory()')));
  });

  test('active-line checks ignore commented directives', () {
    expect(
      _hasActiveLine(
        '# platform: linux/amd64',
        RegExp(r'^\s*platform:\s*linux/amd64\s*$'),
      ),
      isFalse,
    );
  });

  test(
    'native platforms do not ship with placeholder application identifiers',
    () {
      const applicationId = 'com.fosscanner.app';
      const testApplicationId = '$applicationId.RunnerTests';

      _expectXcodeBundleIds(
        path: 'ios/Runner.xcodeproj/project.pbxproj',
        targetSetting: 'INFOPLIST_FILE = Runner/Info.plist',
        bundleId: applicationId,
      );
      _expectXcodeBundleIds(
        path: 'ios/Runner.xcodeproj/project.pbxproj',
        targetSetting: 'TEST_HOST =',
        bundleId: testApplicationId,
      );
      _expectXcodeBundleIds(
        path: 'macos/Runner.xcodeproj/project.pbxproj',
        targetSetting: 'TEST_HOST =',
        bundleId: testApplicationId,
      );

      final macosConfig = File(
        'macos/Runner/Configs/AppInfo.xcconfig',
      ).readAsStringSync();
      expect(
        _assignmentValues(macosConfig, 'PRODUCT_BUNDLE_IDENTIFIER'),
        equals({applicationId}),
      );

      final linuxCmake = File('linux/CMakeLists.txt').readAsStringSync();
      expect(
        RegExp(
          r'^\s*set\(APPLICATION_ID\s+"([^"]+)"\)\s*$',
          multiLine: true,
        ).firstMatch(_activeSource(linuxCmake))?.group(1),
        applicationId,
      );

      final windowsResources = File(
        'windows/runner/Runner.rc',
      ).readAsStringSync();
      expect(
        RegExp(
          r'^\s*VALUE "CompanyName",\s*"([^"]+)"\s*"\\0"\s*$',
          multiLine: true,
        ).firstMatch(_activeSource(windowsResources))?.group(1),
        'FOSScanner',
      );

      for (final path in [
        'ios/Runner.xcodeproj/project.pbxproj',
        'macos/Runner.xcodeproj/project.pbxproj',
        'macos/Runner/Configs/AppInfo.xcconfig',
        'linux/CMakeLists.txt',
        'windows/runner/Runner.rc',
      ]) {
        expect(
          File(path).readAsStringSync(),
          isNot(contains('com.example')),
          reason: path,
        );
      }
    },
  );

  test(
    'workflow actions use approved immutable revisions and Flutter version',
    () {
      const approvedActions = {
        'actions/checkout': (
          sha: '11d5960a326750d5838078e36cf38b85af677262',
          version: 'v4',
        ),
        'subosito/flutter-action': (
          sha: '1a449444c387b1966244ae4d4f8c696479add0b2',
          version: 'v2',
        ),
        'actions/upload-artifact': (
          sha: 'ea165f8d65b6e75b540449e92b4886f43607fa02',
          version: 'v4',
        ),
        'actions/setup-java': (
          sha: 'cf277c60eb25467037889841efdb72551f06f6c3',
          version: 'v4',
        ),
        'softprops/action-gh-release': (
          sha: '3bb12739c298aeb8a4eeaf626c5b8d85266b0e65',
          version: 'v2',
        ),
        'actions/attest-build-provenance': (
          sha: '43d14bc2b83dec42d39ecae14e916627a18bb661',
          version: 'v3',
        ),
        'googleapis/release-please-action': (
          sha: '8b8fd2cc23b2e18957157a9d923d75aa0c6f6ad5',
          version: 'v4',
        ),
      };
      final actionPattern = RegExp(
        r'^\s*(?:-\s+)?uses:\s*([^@\s]+)@([^\s#]+)\s+#\s*(v\d+)\s*$',
        multiLine: true,
      );

      for (final workflow
          in Directory('.github/workflows').listSync().whereType<File>().where(
            (file) => file.path.endsWith('.yml'),
          )) {
        final source = workflow.readAsStringSync();
        final usesLines = RegExp(
          r'^\s*(?:-\s+)?uses:',
          multiLine: true,
        ).allMatches(_activeSource(source)).length;
        final actions = actionPattern
            .allMatches(_activeSource(source))
            .toList();
        expect(
          actions,
          hasLength(usesLines),
          reason: '${workflow.path} action pin/comment',
        );

        for (final action in actions) {
          final name = action.group(1)!;
          final approved = approvedActions[name];
          expect(approved, isNotNull, reason: '${workflow.path}: $name');
          expect(
            action.group(2),
            approved!.sha,
            reason: '${workflow.path}: $name',
          );
          expect(
            action.group(3),
            approved.version,
            reason: '${workflow.path}: $name',
          );
        }

        for (final step in _workflowSteps(
          source,
        ).where((step) => step.action == 'subosito/flutter-action')) {
          expect(
            step.source,
            matches(
              RegExp(
                r'''^\s+flutter-version:\s*['"]?3\.44\.0['"]?\s*$''',
                multiLine: true,
              ),
            ),
            reason: workflow.path,
          );
        }

        for (final job in _workflowJobs(source).values.where(
          (job) => _workflowRunCommands(
            job.source,
          ).any((command) => command.contains('flutter ')),
        )) {
          expect(
            _workflowSteps(job.source).map((step) => step.action),
            contains('subosito/flutter-action'),
            reason: '${workflow.path}: ${job.name} must install pinned Flutter',
          );
        }
      }

      expect(File('.flutter-version').readAsStringSync().trim(), '3.44.0');
    },
  );

  test('Docker context is private and services use narrow exposure', () {
    final dockerfile = File('Dockerfile').readAsStringSync();
    expect(
      _hasActiveLine(
        dockerfile,
        RegExp(
          r'^FROM ghcr\.io/cirruslabs/flutter@sha256:'
          r'46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8\s*$',
        ),
      ),
      isTrue,
    );
    expect(
      _hasActiveLine(dockerfile, RegExp(r'^\s*ninja-build\s*\\\s*$')),
      isTrue,
    );
    expect(
      _hasActiveLine(dockerfile, RegExp(r'^\s*RUN flutter pub get\s*$')),
      isTrue,
    );

    final dockerignore = File('.dockerignore');
    expect(dockerignore.existsSync(), isTrue);
    if (!dockerignore.existsSync()) return;
    final ignored = _activeLines(dockerignore.readAsStringSync())
        .map((line) => line.trim().replaceFirst(RegExp(r'/$'), ''))
        .where((line) => line.isNotEmpty)
        .toSet();
    expect(
      ignored,
      containsAll({
        '.env',
        '.env.*',
        '*.jks',
        '*.keystore',
        'android/key.properties',
        'build',
        '.dart_tool',
        '.git',
        '.idea',
        '.vscode',
        '*.iml',
        'android/local.properties',
        'docker-output',
        '.clean-check-tmp',
      }),
    );
    expect(
      ignored.where((pattern) => pattern.startsWith('!')),
      isEmpty,
      reason: 'Docker ignore exclusions must not be re-included later',
    );
    final gitIgnored = _activeLines(
      File('.gitignore').readAsStringSync(),
    ).map((line) => line.trim().replaceAll(RegExp(r'^/|/$'), '')).toSet();
    expect(gitIgnored, containsAll({'docker-output', '.clean-check-tmp'}));

    final compose = File('docker-compose.yml').readAsStringSync();
    final activeCompose = _activeSource(compose);
    expect(compose, isNot(contains('flutter create .')));
    final publishedPorts = _yamlListValues(compose, 'ports');
    expect(publishedPorts, contains('127.0.0.1:8080:8080'));
    expect(
      publishedPorts,
      everyElement(startsWith('127.0.0.1:')),
      reason: 'Every Docker host port must bind only to loopback',
    );
    final volumes = _yamlListValues(compose, 'volumes');
    expect(volumes, equals(['./docker-output:/app/docker-output']));
    expect(
      _hasActiveLine(compose, RegExp(r'^\s*platform:\s*linux/amd64\s*$')),
      isTrue,
    );
    final apkCommands = RegExp(
      r'flutter build apk\b[^\n"]*',
    ).allMatches(activeCompose).map((match) => match.group(0)!);
    expect(apkCommands, isNotEmpty);
    expect(apkCommands, everyElement(contains('--debug')));
    expect(
      activeCompose,
      contains('flutter build apk --debug --split-per-abi'),
    );
    expect(activeCompose, contains('/app/docker-output/'));
    expect(File('README.md').readAsStringSync(), contains('./docker-output/'));
    expect(
      _activeSource(dockerfile),
      matches(RegExp(r'^COPY \. \.$', multiLine: true)),
    );
  });

  test('Android release signing cannot fall back to a debug key', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final active = _activeSource(gradle);
    expect(active, isNot(contains('signingConfigs.getByName("debug")')));
    expect(active, contains('gradle.taskGraph.whenReady'));
    expect(
      active,
      contains(
        r'Regex("^(assemble|bundle|package).*Release(?:Bundle|UniversalApk)?\$")',
      ),
    );
    expect(
      active,
      matches(
        RegExp(
          r'requestsReleaseArtifact\s*&&\s*!hasReleaseKeystore[\s\S]*throw GradleException'
          r'[\s\S]*Release signing is required',
        ),
      ),
    );

    final releaseArtifactTask = RegExp(
      r'^(assemble|bundle|package).*Release(?:Bundle|UniversalApk)?$',
    );
    for (final task in [
      'assembleRelease',
      'assembleFossRelease',
      'bundleRelease',
      'packageReleaseBundle',
      'packageReleaseUniversalApk',
    ]) {
      expect(releaseArtifactTask.hasMatch(task), isTrue, reason: task);
    }
    for (final task in [
      'lintRelease',
      'testReleaseUnitTest',
      'packageReleaseResources',
      'assembleReleaseUnitTest',
      'assembleDebug',
    ]) {
      expect(releaseArtifactTask.hasMatch(task), isFalse, reason: task);
    }
  });

  test('Gradle distribution has the approved checksum', () {
    final properties = _activeSource(
      File(
        'android/gradle/wrapper/gradle-wrapper.properties',
      ).readAsStringSync(),
    );
    final values = {
      for (final line in properties.split('\n'))
        if (line.contains('='))
          line.substring(0, line.indexOf('=')): line.substring(
            line.indexOf('=') + 1,
          ),
    };
    expect(
      values['distributionUrl'],
      r'https\://services.gradle.org/distributions/gradle-9.1.0-all.zip',
    );
    expect(
      values['distributionSha256Sum'],
      'b84e04fa845fecba48551f425957641074fcc00a88a84d2aae5808743b35fc85',
    );
  });

  test(
    'release preflight validates the tag before the release environment',
    () {
      final release = File('.github/workflows/release.yml').readAsStringSync();
      expect(
        _yamlListValues(release, 'tags'),
        equals(['v[0-9]*.[0-9]*.[0-9]*']),
      );

      final jobs = _workflowJobs(release);
      expect(jobs.keys, equals(['preflight', 'build-and-release']));
      final preflight = jobs['preflight']!;
      final build = jobs['build-and-release']!;
      expect(preflight.source, isNot(contains('environment:')));
      expect(preflight.source, isNot(contains(r'${{ secrets.')));
      expect(
        build.source,
        matches(RegExp(r'^\s+needs:\s*preflight\s*$', multiLine: true)),
      );
      expect(
        build.source,
        matches(RegExp(r'^\s+environment:\s*release\s*$', multiLine: true)),
      );

      final preflightCommands = _workflowRunCommands(
        preflight.source,
      ).join('\n');
      const exactSemverPattern =
          r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$';
      expect(preflightCommands, contains(exactSemverPattern));
      final exactSemver = RegExp(exactSemverPattern);
      for (final tag in ['v0.0.0', 'v1.2.2', 'v10.20.30']) {
        expect(exactSemver.hasMatch(tag), isTrue, reason: tag);
      }
      for (final tag in ['v01.2.2', 'v1.2', 'v1.2.2-rc.1', 'v1.2.2+5']) {
        expect(exactSemver.hasMatch(tag), isFalse, reason: tag);
      }
      expect(
        preflightCommands,
        contains(r'git merge-base --is-ancestor "$GITHUB_SHA" "origin/main"'),
      );
      expect(preflightCommands, contains('pubspec.yaml'));
      expect(preflightCommands, contains(r'${pubspec_version%%+*}'));
      expect(
        preflightCommands,
        contains(r'"$GITHUB_REF_NAME" != "v$release_version"'),
      );
      for (final command in [
        'flutter pub get',
        'flutter analyze',
        'flutter test',
      ]) {
        expect(preflightCommands, contains(command), reason: command);
      }

      final preflightCheckout = _workflowSteps(
        preflight.source,
      ).singleWhere((step) => step.action == 'actions/checkout');
      expect(
        preflightCheckout.source,
        matches(RegExp(r'^\s+fetch-depth:\s*0\s*$', multiLine: true)),
      );
      final buildCheckout = _workflowSteps(
        build.source,
      ).singleWhere((step) => step.action == 'actions/checkout');
      expect(
        buildCheckout.source,
        contains(r'ref: ${{ needs.preflight.outputs.validated-sha }}'),
      );
    },
  );

  test('release attests every APK and fails if publishing matches nothing', () {
    final release = File('.github/workflows/release.yml').readAsStringSync();
    final jobs = _workflowJobs(release);
    final preflight = jobs['preflight']!;
    final build = jobs['build-and-release']!;
    expect(preflight.source, isNot(contains('id-token:')));
    expect(preflight.source, isNot(contains('attestations:')));
    for (final permission in [
      'contents: read',
      'id-token: write',
      'attestations: write',
    ]) {
      expect(build.source, contains(permission), reason: permission);
    }

    final steps = _workflowSteps(build.source);
    final buildIndex = steps.indexWhere(
      (step) => step.run?.contains('flutter build apk --release') ?? false,
    );
    final attestIndex = steps.indexWhere(
      (step) => step.action == 'actions/attest-build-provenance',
    );
    expect(buildIndex, greaterThanOrEqualTo(0));
    expect(attestIndex, greaterThan(buildIndex));
    expect(
      steps[attestIndex].source,
      contains('subject-path: build/app/outputs/flutter-apk/app-*-release.apk'),
    );

    final publish = steps.singleWhere(
      (step) => step.action == 'softprops/action-gh-release',
    );
    expect(publish.source, contains('fail_on_unmatched_files: true'));
  });

  test('release PAT is scoped to publishing action steps', () {
    final releaseWorkflows = [
      File('.github/workflows/release.yml'),
      File('.github/workflows/release-please.yml'),
    ];

    for (final workflow in releaseWorkflows) {
      final active = _activeSource(workflow.readAsStringSync());
      final patSteps = _workflowSteps(
        active,
      ).where((step) => step.source.contains('secrets.RELEASE_TOKEN')).toList();
      expect(patSteps, hasLength(1), reason: workflow.path);
      expect(
        patSteps.single.action,
        anyOf(
          'softprops/action-gh-release',
          'googleapis/release-please-action',
        ),
        reason: workflow.path,
      );
    }
  });

  test('CI builds every supported platform and runs quality once', () {
    final source = File('.github/workflows/ci.yml').readAsStringSync();
    final jobs = _workflowJobs(source);

    _WorkflowJob jobWith(String command) => jobs.values.singleWhere(
      (job) =>
          _workflowRunCommands(job.source).any((run) => run.contains(command)),
      orElse: () => throw TestFailure('No CI job runs `$command`'),
    );

    expect(_runner(jobWith('flutter analyze')), 'ubuntu-latest');
    expect(_runner(jobWith('flutter build web')), 'ubuntu-latest');
    expect(_runner(jobWith('flutter build linux')), 'ubuntu-latest');
    expect(_runner(jobWith('flutter build apk --debug')), 'ubuntu-latest');
    expect(_runner(jobWith('flutter build ios --no-codesign')), 'macos-latest');
    expect(_runner(jobWith('flutter build macos')), 'macos-latest');
    expect(_runner(jobWith('flutter build windows')), 'windows-latest');

    final commands = _workflowRunCommands(source).toList();
    expect(commands.where((run) => run.contains('flutter test')), hasLength(1));
    expect(
      commands.where((run) => run.contains('flutter analyze')),
      hasLength(1),
    );
  });

  test('Dependabot covers Docker dependencies', () {
    final source = File('.github/dependabot.yml').readAsStringSync();
    expect(
      RegExp(
        r'''^\s*-\s+package-ecosystem:\s*['"]docker['"]\s*$''',
        multiLine: true,
      ).hasMatch(_activeSource(source)),
      isTrue,
    );
  });

  test('public platform and privacy wording matches supported behavior', () {
    final contributing = File(
      'CONTRIBUTING.md',
    ).readAsStringSync().toLowerCase();
    for (final platform in [
      'android',
      'ios',
      'web',
      'linux',
      'macos',
      'windows',
    ]) {
      expect(
        contributing,
        contains(platform),
        reason: 'CONTRIBUTING.md: $platform',
      );
    }

    final issueTemplate = File(
      '.github/ISSUE_TEMPLATE/bug_report.yml',
    ).readAsStringSync();
    final platforms = _yamlListValues(issueTemplate, 'options').toSet();
    expect(
      platforms,
      containsAll({'Android', 'iOS', 'Web', 'Linux', 'macOS', 'Windows'}),
    );

    final fastlane = File(
      'fastlane/metadata/android/en-US/full_description.txt',
    ).readAsStringSync();
    expect(
      fastlane,
      matches(RegExp(r'OS-managed\s+cache', caseSensitive: false)),
    );
    expect(
      fastlane,
      matches(
        RegExp(r'app-owned\s+camera\s+temp\s+files', caseSensitive: false),
      ),
    );
  });
}
