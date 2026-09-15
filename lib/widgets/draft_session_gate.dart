import 'package:flutter/material.dart';

import '../services/draft_session.dart';

/// Prevents restoration and image intake until this app owns its draft.
class DraftSessionGate extends StatefulWidget {
  const DraftSessionGate({
    super.key,
    required this.session,
    required this.child,
  });

  final DraftSessionStore session;
  final Widget child;

  @override
  State<DraftSessionGate> createState() => _DraftSessionGateState();
}

class _DraftSessionGateState extends State<DraftSessionGate> {
  late Future<void> _acquisition = Future<void>.sync(
    widget.session.acquireSession,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _acquisition,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
          !snapshot.hasError) {
        return widget.child;
      }
      final failed =
          snapshot.connectionState == ConnectionState.done && snapshot.hasError;
      final busy = snapshot.error is DraftInUseException;
      return Scaffold(
        appBar: AppBar(title: const Text('FOSScanner')),
        body: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: failed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          busy
                              ? 'Draft already open'
                              : 'Could not open the saved draft',
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          busy
                              ? 'Close the other FOSScanner window, then try again.'
                              : 'Check storage access and try again.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: () => setState(() {
                            _acquisition = Future<void>.sync(
                              widget.session.acquireSession,
                            );
                          }),
                          child: const Text('Retry'),
                        ),
                      ],
                    )
                  : const CircularProgressIndicator(
                      semanticsLabel: 'Opening draft',
                    ),
            ),
          ),
        ),
      );
    },
  );
}
