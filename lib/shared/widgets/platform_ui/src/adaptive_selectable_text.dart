import 'package:material_ui/material_ui.dart';

/// Text the user can select and copy.
class AdaptiveSelectableText extends StatelessWidget {
  const AdaptiveSelectableText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => SelectableText(text, style: style);
}
