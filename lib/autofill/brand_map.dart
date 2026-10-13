/// Services worth impersonating, and what they actually are.
///
/// Trust on first use has one weakness: the first use. If the very first app
/// claiming to be your bank is the fake one, pinning its signature pins the
/// attacker. This table closes that gap for the names people actually get
/// phished for.
///
/// Two deliberate limits.
///
/// It holds no certificate fingerprints. Those have to be read from real
/// installs rather than looked up, and inventing them would be worse than
/// useless: a wrong fingerprint blocks the real app and teaches the user to
/// click through warnings.
///
/// It only ever produces a **positive** signal, never an authorisation. A
/// package listed here is one this table recognises. A package not listed is
/// simply unknown, which is the normal case for regional apps and forks.
library;

class KnownBrand {
  final String name;
  final List<String> domains;

  /// Packages this table recognises. Not exhaustive, and never a whitelist.
  final List<String> androidPackages;

  const KnownBrand({
    required this.name,
    required this.domains,
    this.androidPackages = const [],
  });
}

/// What the table can say about a request.
enum BrandVerdict {
  /// The package is the one recorded for this brand.
  recognised,

  /// The entry looks like a brand in the table, and this is not its app.
  /// Not proof of an attack: it may be a regional app or one this table has
  /// never heard of. It is a reason to ask rather than to fill silently.
  mismatch,

  /// Nothing in the table applies.
  unknown,
}

const List<KnownBrand> knownBrands = [
  KnownBrand(
    name: 'Google',
    domains: ['google.com', 'gmail.com', 'youtube.com'],
    androidPackages: [
      'com.google.android.gm',
      'com.google.android.youtube',
      'com.google.android.googlequicksearchbox',
    ],
  ),
  KnownBrand(
    name: 'Facebook',
    domains: ['facebook.com', 'fb.com'],
    androidPackages: ['com.facebook.katana', 'com.facebook.lite'],
  ),
  KnownBrand(
    name: 'Instagram',
    domains: ['instagram.com'],
    androidPackages: ['com.instagram.android'],
  ),
  KnownBrand(
    name: 'WhatsApp',
    domains: ['whatsapp.com'],
    androidPackages: ['com.whatsapp', 'com.whatsapp.w4b'],
  ),
  KnownBrand(
    name: 'X',
    domains: ['x.com', 'twitter.com'],
    androidPackages: ['com.twitter.android'],
  ),
  KnownBrand(
    name: 'LinkedIn',
    domains: ['linkedin.com'],
    androidPackages: ['com.linkedin.android'],
  ),
  KnownBrand(
    name: 'Telegram',
    domains: ['telegram.org'],
    androidPackages: ['org.telegram.messenger'],
  ),
  KnownBrand(
    name: 'Snapchat',
    domains: ['snapchat.com'],
    androidPackages: ['com.snapchat.android'],
  ),
  KnownBrand(
    name: 'Reddit',
    domains: ['reddit.com'],
    androidPackages: ['com.reddit.frontpage'],
  ),
  KnownBrand(
    name: 'Discord',
    domains: ['discord.com'],
    androidPackages: ['com.discord'],
  ),
  KnownBrand(
    name: 'Netflix',
    domains: ['netflix.com'],
    androidPackages: ['com.netflix.mediaclient'],
  ),
  KnownBrand(
    name: 'Spotify',
    domains: ['spotify.com'],
    androidPackages: ['com.spotify.music'],
  ),
  KnownBrand(
    name: 'Amazon',
    domains: ['amazon.com', 'amazon.in', 'amazon.co.uk'],
    // The global app, and Amazon India's, which has a package of its own.
    androidPackages: [
      'com.amazon.mShop.android.shopping',
      'in.amazon.mShop.android.shopping',
    ],
  ),
  KnownBrand(
    name: 'Microsoft',
    domains: ['microsoft.com', 'live.com', 'outlook.com', 'office.com'],
    androidPackages: [
      'com.microsoft.office.outlook',
      'com.microsoft.skydrive',
    ],
  ),
  KnownBrand(
    name: 'Apple',
    domains: ['apple.com', 'icloud.com'],
  ),
  KnownBrand(
    name: 'PayPal',
    domains: ['paypal.com'],
    androidPackages: ['com.paypal.android.p2pmobile'],
  ),
  KnownBrand(
    name: 'Dropbox',
    domains: ['dropbox.com'],
    androidPackages: ['com.dropbox.android'],
  ),
  KnownBrand(
    name: 'GitHub',
    domains: ['github.com'],
    androidPackages: ['com.github.android'],
  ),
  KnownBrand(
    name: 'Uber',
    domains: ['uber.com'],
    androidPackages: ['com.ubercab'],
  ),
  KnownBrand(
    name: 'Airbnb',
    domains: ['airbnb.com'],
    androidPackages: ['com.airbnb.android'],
  ),
  KnownBrand(
    name: 'eBay',
    domains: ['ebay.com'],
    androidPackages: ['com.ebay.mobile'],
  ),
  KnownBrand(
    name: 'Flipkart',
    domains: ['flipkart.com'],
    androidPackages: ['com.flipkart.android'],
  ),
  KnownBrand(
    name: 'Paytm',
    domains: ['paytm.com'],
    androidPackages: ['net.one97.paytm'],
  ),
  KnownBrand(
    name: 'PhonePe',
    domains: ['phonepe.com'],
    androidPackages: ['com.phonepe.app'],
  ),
  KnownBrand(
    name: 'Google Pay',
    domains: ['pay.google.com'],
    androidPackages: ['com.google.android.apps.nbu.paisa.user'],
  ),
  // Banks are listed by domain only. Their app packages vary by region and
  // by outsourced developer, and a wrong one here would cry wolf on the real
  // app, which is the fastest way to train someone to ignore warnings.
  KnownBrand(name: 'HDFC Bank', domains: ['hdfcbank.com']),
  KnownBrand(name: 'ICICI Bank', domains: ['icicibank.com']),
  KnownBrand(name: 'State Bank of India', domains: ['onlinesbi.sbi', 'sbi.co.in']),
  KnownBrand(name: 'Axis Bank', domains: ['axisbank.com']),
  KnownBrand(name: 'Kotak', domains: ['kotak.com']),
  KnownBrand(name: 'Chase', domains: ['chase.com']),
  KnownBrand(name: 'Bank of America', domains: ['bankofamerica.com']),
  KnownBrand(name: 'Wells Fargo', domains: ['wellsfargo.com']),
  KnownBrand(name: 'Citi', domains: ['citi.com', 'citibank.com']),
  KnownBrand(name: 'HSBC', domains: ['hsbc.com', 'hsbc.co.uk']),
  KnownBrand(name: 'Barclays', domains: ['barclays.co.uk']),
  KnownBrand(name: 'Revolut', domains: ['revolut.com']),
  KnownBrand(name: 'Wise', domains: ['wise.com']),
  KnownBrand(name: 'Coinbase', domains: ['coinbase.com']),
  KnownBrand(name: 'Binance', domains: ['binance.com']),
];

/// Finds the brand an entry title refers to, if the table knows it.
///
/// Brand names are matched as whole words. A plain "contains" treated any
/// title with an x in it as the brand X, "Purchase" as Chase and "Pineapple"
/// as Apple, and a warning that fires on "Example Bank" teaches people to
/// ignore it on the day it is right.
KnownBrand? brandForTitle(String title) {
  final needle = title.toLowerCase();
  for (final brand in knownBrands) {
    final word = RegExp(
      '(^|[^a-z0-9])${RegExp.escape(brand.name.toLowerCase())}(\$|[^a-z0-9])',
    );
    if (word.hasMatch(needle)) return brand;
  }
  return null;
}

KnownBrand? brandForDomain(String registrableDomain) {
  final needle = registrableDomain.toLowerCase();
  for (final brand in knownBrands) {
    if (brand.domains.contains(needle)) return brand;
  }
  return null;
}

KnownBrand? brandForPackage(String packageName) {
  for (final brand in knownBrands) {
    if (brand.androidPackages.contains(packageName)) return brand;
  }
  return null;
}

/// Checks an entry title against the website it is about to be linked to.
///
/// Like [checkPackageAgainstTitle], a warning and never a decision: an entry
/// called "PayPal" going to "paypal-secure-login.com" is worth a second look.
BrandVerdict checkDomainAgainstTitle({
  required String entryTitle,
  required String registrableDomain,
}) {
  final brand = brandForTitle(entryTitle);
  if (brand == null || brand.domains.isEmpty) return BrandVerdict.unknown;
  return brand.domains.contains(registrableDomain.toLowerCase())
      ? BrandVerdict.recognised
      : BrandVerdict.mismatch;
}

/// Checks an entry title against the app that is asking.
///
/// Used on a first fill, where there is no pinned signature to compare and
/// the user is about to create one.
BrandVerdict checkPackageAgainstTitle({
  required String entryTitle,
  required String packageName,
}) {
  final brand = brandForTitle(entryTitle);
  if (brand == null || brand.androidPackages.isEmpty) {
    return BrandVerdict.unknown;
  }
  return brand.androidPackages.contains(packageName)
      ? BrandVerdict.recognised
      : BrandVerdict.mismatch;
}
