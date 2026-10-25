/// What the free plan holds, and what happens when it is full.
///
/// Free: up to [freeLogins] logins in a vault. A subscription lifts the
/// limit and adds sync between devices. When a subscription ends, nothing
/// already saved is taken away: every login can still be seen, searched,
/// copied, filled, edited, deleted and exported. Only adding more is held
/// until there is room again, or a subscription.
library;

/// How many logins a vault holds without a subscription.
const int freeLogins = 20;

/// Room for new logins in a vault holding [count]: unlimited with a
/// subscription, otherwise what is left of [freeLogins] (never negative).
int roomLeft({required int count, required bool subscribed}) =>
    subscribed ? _unlimited : (freeLogins - count).clamp(0, freeLogins);

/// [roomLeft] with a subscription; large enough never to be reached.
const int _unlimited = 1 << 30;

/// Adding was refused: the vault is on the free plan and full.
///
/// [count] logins are in the vault, [wanted] were to be added, and [room]
/// of them would have fitted. Nothing was added: an import either goes in
/// whole or not at all.
class FreePlanFull implements Exception {
  final int count;
  final int wanted;
  final int room;

  const FreePlanFull({required this.count, required this.wanted, required this.room});

  @override
  String toString() => 'FreePlanFull: $count saved, $wanted to add, room for $room';
}
