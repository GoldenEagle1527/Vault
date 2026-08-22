import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:vault_agent_core/src/agent/skill.dart' as facade;
import 'package:vault_agent_core/src/agent/skill/activation_tools.dart';
import 'package:vault_agent_core/src/agent/skill/directory_loader.dart';
import 'package:vault_agent_core/src/agent/skill/model.dart' as model;
import 'package:vault_agent_core/src/agent/skill/prompt_injection.dart';
import 'package:vault_agent_core/src/agent/stateful_agent.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/core/message.dart';
import 'package:vault_agent_core/src/core/tool.dart';

void main() {
  group('skill model partition', () {
    test('compatibility facade re-exports the model type', () {
      final skill = _TestSkill(
        name: 'core',
        systemPrompt: 'Always follow the core workflow.',
        forceActivate: true,
      );

      expect(skill, isA<facade.Skill>());
      expect(skill.forceActivate, isTrue);
    });

    test('activation partition exposes the existing operation tools', () {
      expect(skillOperationTools.map((tool) => tool.name), [
        'activate_skills',
        'deactivate_skills',
      ]);
      expect(
        skillOperationTools.every(
          (tool) => tool.parameters['required'] != null,
        ),
        isTrue,
      );
    });

    test('activation tools mutate only optional skills', () {
      final state = AgentState.empty();
      final agent = StatefulAgent(
        name: 'skill-test',
        client: _UnusedClient(),
        modelConfig: ModelConfig(model: 'unused'),
        state: state,
        skills: [
          _TestSkill(name: 'optional', systemPrompt: 'Optional'),
          _TestSkill(name: 'core', systemPrompt: 'Core', forceActivate: true),
        ],
      );
      final context = AgentCallToolContext(
        state: state,
        agent: agent,
        batchCallId: 'batch',
        callId: 'call',
        toolName: 'activate_skills',
      );

      final activated = runZoned(
        () =>
            Function.apply(skillOperationTools.first.executable!, [
                  ['optional', 'core', 'missing'],
                ])
                as String,
        zoneValues: {AgentCallToolContext.zoneKey: context},
      );
      final deactivated = runZoned(
        () =>
            Function.apply(skillOperationTools.last.executable!, [
                  ['optional', 'core'],
                ])
                as String,
        zoneValues: {AgentCallToolContext.zoneKey: context},
      );

      expect(activated, contains('Skills have been activated: optional'));
      expect(activated, contains('Skills have been force activated: core'));
      expect(activated, contains('Skills not found: missing'));
      expect(deactivated, contains('Skills have been deactivated: optional'));
      expect(deactivated, contains('Skills are force activated: core'));
      expect(state.activeSkills, isEmpty);
    });
  });

  group('directory skill loader partition', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('vault_skill_partition_');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('loads, parses, normalizes, and sorts skill metadata', () async {
      _writeSkill(
        root,
        'zeta',
        "---\nname: zeta\ndescription: 'Last skill'\n---\nZeta body",
      );
      _writeSkill(
        root,
        'alpha',
        '---\nname: alpha\ndescription: First skill\n---\nAlpha body',
      );

      final result = await loadDirectorySkillsFromRoot(root.path);

      expect(result.errors, isEmpty);
      expect(result.skills.map((skill) => skill.name), ['alpha', 'zeta']);
      expect(
        result.skills.every(
          (skill) =>
              skill.pathToSkillMd.endsWith('/SKILL.md') &&
              !skill.pathToSkillMd.contains(r'\'),
        ),
        isTrue,
      );
    });

    test('reports malformed and missing skill directories', () async {
      _writeSkill(root, 'invalid', '# no frontmatter');

      final malformed = await loadDirectorySkillsFromRoot(root.path);
      final missing = await loadDirectorySkillsFromRoot(
        '${root.path}${Platform.pathSeparator}missing',
      );

      expect(malformed.skills, isEmpty);
      expect(malformed.errors.single.message, contains('frontmatter'));
      expect(missing.errors.single.message, 'skill directory does not exist');
    });

    test('injects the selected skill body with metadata', () async {
      final file = _writeSkill(
        root,
        'inject',
        '---\nname: inject\ndescription: Injectable\n---\nFollow this.',
      );
      final metadata = model.DirectorySkillMetadata(
        name: 'inject',
        description: 'Injectable',
        pathToSkillMd: file.path,
      );

      final result = await buildDirectorySkillInjections([metadata]);

      expect(result.warnings, isEmpty);
      expect(
        (result.items.single.contents.single as TextPart).text,
        contains('Follow this.'),
      );
      expect(result.items.single.metadata?['skill_name'], 'inject');
    });
  });

  group('prompt injection partition', () {
    test('includes only active dynamic skill instructions', () {
      final state = AgentState.empty()..activeSkills = ['active'];
      final prompt = buildSkillSystemPrompt(state, [
        _TestSkill(name: 'active', systemPrompt: 'Active instructions'),
        _TestSkill(name: 'inactive', systemPrompt: 'Inactive instructions'),
      ]);

      expect(prompt, isNotNull);
      expect(prompt!.content, contains('Active instructions'));
      expect(prompt.content, isNot(contains('Inactive instructions')));
      expect(prompt.content, contains('⚪ [INACTIVE]'));
    });

    test('adds JavaScript guidance only when execution is enabled', () {
      final skill = model.DirectorySkillMetadata(
        name: 'scripts',
        description: 'Runs scripts',
        pathToSkillMd: '/skills/scripts/SKILL.md',
      );

      final disabled = buildDirectorySkillsSystemPrompt([skill])!.content;
      final enabled = buildDirectorySkillsSystemPrompt([
        skill,
      ], javaScriptExecutionEnabled: true)!.content;

      expect(disabled, isNot(contains('RunJavaScript')));
      expect(enabled, contains('RunJavaScript'));
    });

    test('selects unambiguous explicit and plain-text mentions', () {
      final alpha = model.DirectorySkillMetadata(
        name: 'alpha',
        description: 'Alpha',
        pathToSkillMd: '/skills/alpha/SKILL.md',
      );
      final beta = model.DirectorySkillMetadata(
        name: 'beta',
        description: 'Beta',
        pathToSkillMd: '/skills/beta/SKILL.md',
      );

      final selected = collectExplicitDirectorySkillMentions(
        [UserMessage.text(r'Use $alpha and then beta.')],
        [alpha, beta],
      );

      expect(selected, [alpha, beta]);
    });
  });
}

File _writeSkill(Directory root, String directoryName, String content) {
  final directory = Directory(
    '${root.path}${Platform.pathSeparator}$directoryName',
  )..createSync(recursive: true);
  return File('${directory.path}${Platform.pathSeparator}SKILL.md')
    ..writeAsStringSync(content);
}

class _TestSkill extends model.Skill {
  _TestSkill({
    required super.name,
    required super.systemPrompt,
    super.forceActivate,
  }) : super(description: name);
}

class _UnusedClient implements LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) {
    throw UnimplementedError();
  }
}
