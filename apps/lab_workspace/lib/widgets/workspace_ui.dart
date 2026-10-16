import 'package:flutter/material.dart';

const workspaceCanvas = Color(0xFFF4F7F6);
const workspaceAccent = Color(0xFF14776F);
const workspaceInk = Color(0xFF203331);
const workspaceMutedInk = Color(0xFF63736F);

class WorkspacePageHeader extends StatelessWidget {
  const WorkspacePageHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.actions = const [],
    this.breadcrumbs = const [],
    super.key,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget> actions;
  final List<String> breadcrumbs;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: const Color(0xFFE4F0ED),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: workspaceAccent, size: 23),
        ),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (breadcrumbs.isNotEmpty) ...[
                Wrap(
                  spacing: 7,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (
                      var index = 0;
                      index < breadcrumbs.length;
                      index++
                    ) ...[
                      if (index > 0)
                        const Icon(
                          Icons.chevron_right,
                          size: 15,
                          color: Color(0xFF91A09B),
                        ),
                      Text(
                        breadcrumbs[index],
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: workspaceMutedInk,
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
              ],
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        if (!compact && actions.isNotEmpty) ...[
          const SizedBox(width: 20),
          Flexible(
            child: Align(
              alignment: Alignment.topRight,
              child: Wrap(
                spacing: 9,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: actions,
              ),
            ),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          if (compact && actions.isNotEmpty) ...[
            const SizedBox(height: 15),
            Wrap(spacing: 9, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}

class WorkspaceSectionHeader extends StatelessWidget {
  const WorkspaceSectionHeader({
    required this.title,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class WorkspaceStatusBadge extends StatelessWidget {
  const WorkspaceStatusBadge({
    required this.label,
    this.icon,
    this.tone = WorkspaceBadgeTone.neutral,
    super.key,
  });

  final String label;
  final IconData? icon;
  final WorkspaceBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = switch (tone) {
      WorkspaceBadgeTone.success => (
        background: const Color(0xFFE6F3EA),
        foreground: const Color(0xFF39734D),
        border: const Color(0xFFD0E8D7),
      ),
      WorkspaceBadgeTone.warning => (
        background: const Color(0xFFFFF3DF),
        foreground: const Color(0xFF8A6220),
        border: const Color(0xFFF1E1C2),
      ),
      WorkspaceBadgeTone.danger => (
        background: const Color(0xFFFCEAEA),
        foreground: const Color(0xFF9A4445),
        border: const Color(0xFFF1D4D4),
      ),
      WorkspaceBadgeTone.neutral => (
        background: const Color(0xFFEDF2F1),
        foreground: const Color(0xFF536661),
        border: const Color(0xFFDCE6E3),
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: colors.foreground),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: colors.foreground,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

enum WorkspaceBadgeTone { neutral, success, warning, danger }

class WorkspaceEmptyState extends StatelessWidget {
  const WorkspaceEmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  @override
  Widget build(BuildContext context) => WorkspaceEntrance(
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDCE6E3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: const Color(0xFFEAF3F1),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: workspaceAccent, size: 29),
          ),
          const SizedBox(height: 15),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    ),
  );
}

class WorkspaceEntrance extends StatelessWidget {
  const WorkspaceEntrance({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 8),
          child: child,
        ),
      ),
    );
  }
}

class WorkspaceHoverCard extends StatefulWidget {
  const WorkspaceHoverCard({required this.child, this.onTap, super.key});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<WorkspaceHoverCard> createState() => _WorkspaceHoverCardState();
}

class _WorkspaceHoverCardState extends State<WorkspaceHoverCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180),
    curve: Curves.easeOut,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: _hovered ? const Color(0xFFBFD9D3) : const Color(0xFFDCE6E3),
      ),
      boxShadow: _hovered
          ? const [
              BoxShadow(
                color: Color(0x101C5650),
                blurRadius: 18,
                offset: Offset(0, 7),
              ),
            ]
          : const [],
    ),
    child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: widget.onTap, child: widget.child),
      ),
    ),
  );
}
