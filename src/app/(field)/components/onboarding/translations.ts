export type Language = 'en' | 'hi' | 'ta' | 'ml' | 'tl'

export type TooltipPosition = 'top' | 'bottom' | 'left' | 'right' | 'center'

export interface TourStep {
  targetId: string
  tooltipPosition: TooltipPosition
  title: string
  body: string
  buttonNext: string
  buttonSkip: string
  buttonDone: string
}

export type PageTourId = 'packing' | 'dispatching' | 'inventory' | 'tasks'

export interface TranslationSet {
  languagePicker: {
    title: string
    subtitle: string
    confirm: string
  }
  warehouseTour: TourStep[]
  driverTour: TourStep[]
  pageTours: Record<PageTourId, TourStep[]>
}

// ─── Helper ───────────────────────────────────────────────────────────────────

function wSteps(
  steps: { targetId: string; tooltipPosition: TooltipPosition; title: string; body: string }[],
  buttonNext: string,
  buttonSkip: string,
  buttonDone: string
): TourStep[] {
  return steps.map((s) => ({ ...s, buttonNext, buttonSkip, buttonDone }))
}

// ─── Translations ─────────────────────────────────────────────────────────────

export const translations: Record<Language, TranslationSet> = {
  en: {
    languagePicker: {
      title: 'Choose your language',
      subtitle: 'Select the language for your app tour',
      confirm: 'Continue',
    },
    warehouseTour: wSteps(
      [
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'Daily Refills',
          body: "This section shows today's packing progress. You can see how many machines need to be packed, picked up, and dispatched.",
        },
        {
          targetId: 'procurement',
          tooltipPosition: 'bottom',
          title: 'Procurement',
          body: 'Use this section to manage purchase orders. You can create new orders, track pending deliveries, and receive stock.',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'Inventory',
          body: 'This section shows your full warehouse stock. Use the expiry alerts to act quickly on items expiring soon.',
        },
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'Tap any card to go deeper',
          body: "Tap Packing to open today's machines. Tick each shelf slot as you pack it. Stock levels are colour-coded — green means plenty, red means low or expired.",
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: "You're ready!",
          body: "The dashboard always shows what needs attention first. Check it at the start of every shift. You can restart this tour from your Profile page.",
        },
      ],
      'Next →',
      'Skip tour',
      'Get started ✓'
    ),
    driverTour: wSteps(
      [
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: "Today's Route",
          body: 'This section shows your machines for today and your progress across packing, pickup, and dispatch.',
        },
        {
          targetId: 'machine-expiry',
          tooltipPosition: 'top',
          title: 'Machine Stock Expiry',
          body: 'If you see an expired product in a machine, flag it here. Your request goes to the warehouse team to confirm the update.',
        },
        {
          targetId: 'profile',
          tooltipPosition: 'top',
          title: 'Profile & Settings',
          body: 'View your profile, sign out, or restart this tour anytime from here.',
        },
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: "You're ready!",
          body: "The dashboard always shows what needs attention first. Check it at the start of every shift. You can restart this tour from your Profile section.",
        },
      ],
      'Next →',
      'Skip tour',
      'Get started ✓'
    ),
    pageTours: {
      packing: wSteps(
        [
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: "Today's machines to pack",
            body: 'Each row is a machine. The progress shows how many shelf slots have been packed. Tap a machine to open it.',
          },
          {
            targetId: 'packing-status',
            tooltipPosition: 'right',
            title: 'Packing status',
            body: 'Green means fully packed and ready for the driver to collect. Grey means packing hasn\'t started yet.',
          },
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'Inside the machine',
            body: 'Tap any row to open the shelf details. Tick each product as you pack it. You\'ll see warehouse stock levels in colour — green is plenty, red is low.',
          },
        ],
        'Next →',
        'Skip tour',
        'Get started ✓'
      ),
      dispatching: wSteps(
        [
          {
            targetId: 'dispatch-photos',
            tooltipPosition: 'bottom',
            title: 'Take photos',
            body: 'Take a photo before you start loading, then another after. This replaces sending photos on WhatsApp.',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'Confirm each product',
            body: 'Tick each shelf slot as you load it into the machine. You can adjust the quantity if you loaded less than planned.',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'Leave a comment',
            body: 'If anything is different from the plan, add a note in the comment field. The office will see it.',
          },
        ],
        'Next →',
        'Skip tour',
        'Get started ✓'
      ),
      inventory: wSteps(
        [
          {
            targetId: 'inventory-filters',
            tooltipPosition: 'bottom',
            title: 'Filter and group your stock',
            body: 'Use the filter to find items expiring soon. Group by Location to see what\'s on each shelf. Group by Category to spot which product types are running low.',
          },
          {
            targetId: 'inventory-list',
            tooltipPosition: 'top',
            title: 'Tap any item to edit',
            body: 'Tap a row to update the quantity, location, or mark it as inactive. Every change is logged with a timestamp.',
          },
        ],
        'Next →',
        'Skip tour',
        'Get started ✓'
      ),
      tasks: wSteps(
        [
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'Supplier collection tasks',
            body: 'These tasks are created when a purchase order needs to be collected in person from Union Coop or Carrefour.',
          },
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'Confirm what you purchased',
            body: "Tap the task to expand it. You'll see the product list. For each item, tap whether you bought it in full, partial, or couldn't get it.",
          },
        ],
        'Next →',
        'Skip tour',
        'Get started ✓'
      ),
    },
  },

  hi: {
    languagePicker: {
      title: 'अपनी भाषा चुनें',
      subtitle: 'ऐप टूर के लिए भाषा चुनें',
      confirm: 'जारी रखें',
    },
    warehouseTour: wSteps(
      [
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'दैनिक रिफिल',
          body: 'यह सेक्शन आज की पैकिंग प्रगति दिखाता है।',
        },
        {
          targetId: 'procurement',
          tooltipPosition: 'bottom',
          title: 'खरीद',
          body: 'यहाँ से नए ऑर्डर बनाएं और डिलीवरी ट्रैक करें।',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'इन्वेंटरी',
          body: 'पूरे वेयरहाउस स्टॉक की जानकारी यहाँ मिलेगी।',
        },
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'किसी भी कार्ड पर टैप करें',
          body: 'पैकिंग खोलें और हर शेल्फ स्लॉट पैक होने पर टिक करें।',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'आप तैयार हैं!',
          body: 'डैशबोर्ड हमेशा सबसे ज़रूरी काम पहले दिखाएगा।',
        },
      ],
      'आगे →',
      'टूर छोड़ें',
      'शुरू करें ✓'
    ),
    driverTour: wSteps(
      [
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: 'आज का रूट',
          body: 'यहाँ आज की मशीनें और आपकी प्रगति दिखती है।',
        },
        {
          targetId: 'machine-expiry',
          tooltipPosition: 'top',
          title: 'मशीन स्टॉक',
          body: 'मशीन में एक्सपायर प्रोडक्ट दिखे तो यहाँ फ्लैग करें।',
        },
        {
          targetId: 'profile',
          tooltipPosition: 'top',
          title: 'प्रोफाइल',
          body: 'यहाँ से साइन आउट करें या टूर दोबारा शुरू करें।',
        },
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: 'आप तैयार हैं!',
          body: 'डैशबोर्ड हमेशा सबसे ज़रूरी काम पहले दिखाएगा।',
        },
      ],
      'आगे →',
      'टूर छोड़ें',
      'शुरू करें ✓'
    ),
    pageTours: {
      packing: wSteps(
        [
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'आज की मशीनें',
            body: 'हर पंक्ति एक मशीन है। प्रगति दिखाती है कि कितने स्लॉट पैक हो गए। मशीन पर टैप करें।',
          },
          {
            targetId: 'packing-status',
            tooltipPosition: 'right',
            title: 'पैकिंग स्थिति',
            body: 'हरा मतलब पूरी तरह पैक हो गई। ग्रे मतलब अभी शुरू नहीं हुई।',
          },
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'मशीन के अंदर',
            body: 'शेल्फ डिटेल्स खोलने के लिए टैप करें। हर प्रोडक्ट पैक करते समय टिक करें।',
          },
        ],
        'आगे →',
        'टूर छोड़ें',
        'शुरू करें ✓'
      ),
      dispatching: wSteps(
        [
          {
            targetId: 'dispatch-photos',
            tooltipPosition: 'bottom',
            title: 'फोटो लें',
            body: 'लोडिंग शुरू करने से पहले और बाद में फोटो लें। यह WhatsApp फोटो की जगह लेता है।',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'हर प्रोडक्ट कन्फर्म करें',
            body: 'मशीन में लोड करते समय हर शेल्फ स्लॉट टिक करें। मात्रा बदल सकते हैं।',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'टिप्पणी छोड़ें',
            body: 'अगर कुछ अलग है तो कमेंट फील्ड में नोट करें। ऑफिस देखेगा।',
          },
        ],
        'आगे →',
        'टूर छोड़ें',
        'शुरू करें ✓'
      ),
      inventory: wSteps(
        [
          {
            targetId: 'inventory-filters',
            tooltipPosition: 'bottom',
            title: 'फिल्टर और ग्रुप',
            body: 'जल्दी एक्सपायर होने वाले आइटम खोजें। लोकेशन या कैटेगरी से ग्रुप करें।',
          },
          {
            targetId: 'inventory-list',
            tooltipPosition: 'top',
            title: 'एडिट करने के लिए टैप करें',
            body: 'मात्रा, लोकेशन अपडेट करें या इनएक्टिव मार्क करें। हर बदलाव लॉग होता है।',
          },
        ],
        'आगे →',
        'टूर छोड़ें',
        'शुरू करें ✓'
      ),
      tasks: wSteps(
        [
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'सप्लायर कलेक्शन टास्क',
            body: 'ये टास्क तब बनते हैं जब PO को सप्लायर से लेना होता है।',
          },
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'खरीदारी कन्फर्म करें',
            body: 'टास्क पर टैप करें। प्रोडक्ट लिस्ट दिखेगी। हर आइटम का परिणाम बताएं।',
          },
        ],
        'आगे →',
        'टूर छोड़ें',
        'शुरू करें ✓'
      ),
    },
  },

  ta: {
    languagePicker: {
      title: 'உங்கள் மொழியை தேர்ந்தெடுக்கவும்',
      subtitle: 'ஆப் டூருக்கான மொழியை தேர்வு செய்யவும்',
      confirm: 'தொடரவும்',
    },
    warehouseTour: wSteps(
      [
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'தினசரி நிரப்புதல்',
          body: 'இன்றைய பேக்கிங் முன்னேற்றம் இங்கே காட்டப்படுகிறது.',
        },
        {
          targetId: 'procurement',
          tooltipPosition: 'bottom',
          title: 'கொள்முதல்',
          body: 'புதிய ஆர்டர்கள் உருவாக்கி டெலிவரி கண்காணிக்கவும்.',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'சரக்கு',
          body: 'முழு கிடங்கு ஸ்டாக் தகவல் இங்கே கிடைக்கும்.',
        },
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'எந்த கார்டையும் தட்டுங்கள்',
          body: 'பேக்கிங் திறந்து ஒவ்வொரு அலமாரியையும் டிக் செய்யுங்கள்.',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'நீங்கள் தயார்!',
          body: 'டாஷ்போர்டு எப்போதும் முக்கியமான பணிகளை முதலில் காட்டும்.',
        },
      ],
      'அடுத்து →',
      'தவிர்',
      'தொடங்குங்கள் ✓'
    ),
    driverTour: wSteps(
      [
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: 'இன்றைய பாதை',
          body: 'இன்றைய இயந்திரங்களும் முன்னேற்றமும் இங்கே தெரியும்.',
        },
        {
          targetId: 'machine-expiry',
          tooltipPosition: 'top',
          title: 'இயந்திர ஸ்டாக்',
          body: 'இயந்திரில் காலாவதியான பொருள் தெரிந்தால் இங்கே கொடியிடவும்.',
        },
        {
          targetId: 'profile',
          tooltipPosition: 'top',
          title: 'சுயவிவரம்',
          body: 'வெளியேறவும் அல்லது டூரை மீண்டும் தொடங்கவும்.',
        },
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: 'நீங்கள் தயார்!',
          body: 'டாஷ்போர்டு எப்போதும் முக்கியமான பணிகளை முதலில் காட்டும்.',
        },
      ],
      'அடுத்து →',
      'தவிர்',
      'தொடங்குங்கள் ✓'
    ),
    pageTours: {
      packing: wSteps(
        [
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'இன்றைய இயந்திரங்கள்',
            body: 'ஒவ்வொரு வரியும் ஒரு இயந்திரம். பேக்கிங் முன்னேற்றம் காட்டப்படுகிறது.',
          },
          {
            targetId: 'packing-status',
            tooltipPosition: 'right',
            title: 'பேக்கிங் நிலை',
            body: 'பச்சை = முழுமையாக பேக். சாம்பல் = இன்னும் தொடங்கவில்லை.',
          },
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'இயந்திரத்தின் உள்ளே',
            body: 'அலமாரி விவரங்களுக்கு தட்டுங்கள். ஒவ்வொரு பொருளையும் டிக் செய்யுங்கள்.',
          },
        ],
        'அடுத்து →',
        'தவிர்',
        'தொடங்குங்கள் ✓'
      ),
      dispatching: wSteps(
        [
          {
            targetId: 'dispatch-photos',
            tooltipPosition: 'bottom',
            title: 'புகைப்படம் எடுங்கள்',
            body: 'ஏற்றுவதற்கு முன்னும் பின்னும் புகைப்படம் எடுங்கள்.',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'ஒவ்வொரு பொருளையும் உறுதிப்படுத்துங்கள்',
            body: 'இயந்திரத்தில் ஏற்றும்போது ஒவ்வொரு ஸ்லாட்டையும் டிக் செய்யுங்கள்.',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'கருத்து சேர்க்கவும்',
            body: 'ஏதாவது வித்தியாசமாக இருந்தால் குறிப்பு சேர்க்கவும்.',
          },
        ],
        'அடுத்து →',
        'தவிர்',
        'தொடங்குங்கள் ✓'
      ),
      inventory: wSteps(
        [
          {
            targetId: 'inventory-filters',
            tooltipPosition: 'bottom',
            title: 'வடிகட்டி & குழு',
            body: 'விரைவில் காலாவதியாகும் பொருட்களைக் கண்டறியுங்கள்.',
          },
          {
            targetId: 'inventory-list',
            tooltipPosition: 'top',
            title: 'திருத்த தட்டுங்கள்',
            body: 'அளவு, இடம் புதுப்பிக்கவும் அல்லது செயலற்றதாக மாற்றவும்.',
          },
        ],
        'அடுத்து →',
        'தவிர்',
        'தொடங்குங்கள் ✓'
      ),
      tasks: wSteps(
        [
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'சப்ளையர் சேகரிப்பு பணிகள்',
            body: 'PO-ஐ சப்ளையரிடமிருந்து சேகரிக்க வேண்டியபோது இந்த பணிகள் உருவாக்கப்படும்.',
          },
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'வாங்கியதை உறுதிப்படுத்துங்கள்',
            body: 'பணியைத் தட்டுங்கள். ஒவ்வொரு பொருளுக்கும் முடிவு தேர்வு செய்யுங்கள்.',
          },
        ],
        'அடுத்து →',
        'தவிர்',
        'தொடங்குங்கள் ✓'
      ),
    },
  },

  ml: {
    languagePicker: {
      title: 'നിങ്ങളുടെ ഭാഷ തിരഞ്ഞെടുക്കൂ',
      subtitle: 'ആപ്പ് ടൂറിനായി ഭാഷ തിരഞ്ഞെടുക്കൂ',
      confirm: 'തുടരുക',
    },
    warehouseTour: wSteps(
      [
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'ദൈനംദിന റീഫിൽ',
          body: 'ഇന്നത്തെ പാക്കിംഗ് പുരോഗതി ഇവിടെ കാണാം.',
        },
        {
          targetId: 'procurement',
          tooltipPosition: 'bottom',
          title: 'സംഭരണം',
          body: 'പുതിയ ഓർഡറുകൾ സൃഷ്ടിക്കാനും ഡെലിവറി ട്രാക്ക് ചെയ്യാനും.',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'ഇൻവെന്ററി',
          body: 'പൂർണ്ണ വെയർഹൗസ് സ്റ്റോക്ക് വിവരങ്ങൾ ഇവിടെ കിട്ടും.',
        },
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'ഏതെങ്കിലും കാർഡ് ടാപ്പ് ചെയ്യൂ',
          body: 'പാക്കിംഗ് തുറന്ന് ഓരോ ഷെൽഫ് സ്ലോട്ടും ടിക് ചെയ്യൂ.',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'നിങ്ങൾ തയ്യാർ!',
          body: 'ഡാഷ്ബോർഡ് എല്ലായ്പ്പോഴും ഏറ്റവും പ്രധാനമായ കാര്യങ്ങൾ ആദ്യം കാണിക്കും.',
        },
      ],
      'അടുത്തത് →',
      'ഒഴിവാക്കൂ',
      'ആരംഭിക്കൂ ✓'
    ),
    driverTour: wSteps(
      [
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: 'ഇന്നത്തെ റൂട്ട്',
          body: 'ഇന്നത്തെ മെഷീനുകളും പുരോഗതിയും ഇവിടെ കാണാം.',
        },
        {
          targetId: 'machine-expiry',
          tooltipPosition: 'top',
          title: 'മെഷീൻ സ്റ്റോക്ക്',
          body: 'മെഷീനിൽ കാലഹരണപ്പെട്ട ഉൽപ്പന്നം കണ്ടാൽ ഇവിടെ ഫ്ലാഗ് ചെയ്യൂ.',
        },
        {
          targetId: 'profile',
          tooltipPosition: 'top',
          title: 'പ്രൊഫൈൽ',
          body: 'സൈൻ ഔട്ട് ചെയ്യാനോ ടൂർ വീണ്ടും ആരംഭിക്കാനോ.',
        },
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: 'നിങ്ങൾ തയ്യാർ!',
          body: 'ഡാഷ്ബോർഡ് എല്ലായ്പ്പോഴും ഏറ്റവും പ്രധാനമായ കാര്യങ്ങൾ ആദ്യം കാണിക്കും.',
        },
      ],
      'അടുത്തത് →',
      'ഒഴിവാക്കൂ',
      'ആരംഭിക്കൂ ✓'
    ),
    pageTours: {
      packing: wSteps(
        [
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'ഇന്നത്തെ മെഷീനുകൾ',
            body: 'ഓരോ വരിയും ഒരു മെഷീൻ ആണ്. പേക്കിംഗ് പുരോഗതി കാണാം.',
          },
          {
            targetId: 'packing-status',
            tooltipPosition: 'right',
            title: 'പേക്കിംഗ് നില',
            body: 'പച്ച = പൂർണ്ണമായി പേക്ക്. ചാരനിറം = ഇതുവരെ തുടങ്ങിയിട്ടില്ല.',
          },
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'മെഷീനിനുള്ളിൽ',
            body: 'ഷെൽഫ് വിശദാംശങ്ങൾ കാണാൻ ടാപ്പ് ചെയ്യൂ. ഓരോ ഉൽപ്പന്നവും ടിക് ചെയ്യൂ.',
          },
        ],
        'അടുത്തത് →',
        'ഒഴിവാക്കൂ',
        'ആരംഭിക്കൂ ✓'
      ),
      dispatching: wSteps(
        [
          {
            targetId: 'dispatch-photos',
            tooltipPosition: 'bottom',
            title: 'ഫോട്ടോ എടുക്കൂ',
            body: 'ലോഡിംഗ് തുടങ്ങുന്നതിന് മുമ്പും ശേഷവും ഫോട്ടോ എടുക്കൂ.',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'ഓരോ ഉൽപ്പന്നവും സ്ഥിരീകരിക്കൂ',
            body: 'മെഷീനിലേക്ക് ലോഡ് ചെയ്യുമ്പോൾ ഓരോ സ്ലോട്ടും ടിക് ചെയ്യൂ.',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'കമന്റ് ചേർക്കൂ',
            body: 'പ്ലാനിൽ നിന്ന് വ്യത്യാസമുണ്ടെങ്കിൽ കമന്റ് ഫീൽഡിൽ കുറിപ്പ് ചേർക്കൂ.',
          },
        ],
        'അടുത്തത് →',
        'ഒഴിവാക്കൂ',
        'ആരംഭിക്കൂ ✓'
      ),
      inventory: wSteps(
        [
          {
            targetId: 'inventory-filters',
            tooltipPosition: 'bottom',
            title: 'ഫിൽട്ടർ & ഗ്രൂപ്പ്',
            body: 'കാലഹരണപ്പെടാൻ പോകുന്ന ഇനങ്ങൾ കണ്ടെത്തുക.',
          },
          {
            targetId: 'inventory-list',
            tooltipPosition: 'top',
            title: 'എഡിറ്റ് ചെയ്യാൻ ടാപ്പ് ചെയ്യൂ',
            body: 'അളവ്, ലൊക്കേഷൻ അപ്ഡേറ്റ് ചെയ്യൂ അല്ലെങ്കിൽ നിഷ്ക്രിയമാക്കൂ.',
          },
        ],
        'അടുത്തത് →',
        'ഒഴിവാക്കൂ',
        'ആരംഭിക്കൂ ✓'
      ),
      tasks: wSteps(
        [
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'സപ്ലയർ കളക്ഷൻ ടാസ്‌ക്കുകൾ',
            body: 'PO സപ്ലയറിൽ നിന്ന് ശേഖരിക്കേണ്ടപ്പോൾ ഈ ടാസ്‌ക്കുകൾ സൃഷ്ടിക്കപ്പെടുന്നു.',
          },
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'വാങ്ങിയത് സ്ഥിരീകരിക്കൂ',
            body: 'ടാസ്‌ക് ടാപ്പ് ചെയ്യൂ. ഓരോ ഇനത്തിനും ഫലം തിരഞ്ഞെടുക്കൂ.',
          },
        ],
        'അടുത്തത് →',
        'ഒഴിവാക്കൂ',
        'ആരംഭിക്കൂ ✓'
      ),
    },
  },

  tl: {
    languagePicker: {
      title: 'Piliin ang iyong wika',
      subtitle: 'Pumili ng wika para sa tour ng app',
      confirm: 'Magpatuloy',
    },
    warehouseTour: wSteps(
      [
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'Araw-araw na Refill',
          body: 'Ipinapakita ng seksyong ito ang pag-usad ng packing ngayon.',
        },
        {
          targetId: 'procurement',
          tooltipPosition: 'bottom',
          title: 'Pagbili',
          body: 'Gumawa ng bagong orders at subaybayan ang mga delivery dito.',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'Imbentaryo',
          body: 'Makikita dito ang buong impormasyon ng stock sa bodega.',
        },
        {
          targetId: 'daily-refills',
          tooltipPosition: 'bottom',
          title: 'I-tap ang kahit anong card',
          body: 'Buksan ang Packing at i-tick ang bawat shelf slot pagkatapos i-pack.',
        },
        {
          targetId: 'inventory',
          tooltipPosition: 'top',
          title: 'Handa na kayo!',
          body: 'Ang dashboard ay palaging nagpapakita ng pinakamahalagang gawain muna.',
        },
      ],
      'Susunod →',
      'Laktawan',
      'Magsimula ✓'
    ),
    driverTour: wSteps(
      [
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: 'Ruta Ngayon',
          body: 'Ipinapakita dito ang iyong mga makina ngayon at ang iyong pag-usad.',
        },
        {
          targetId: 'machine-expiry',
          tooltipPosition: 'top',
          title: 'Stock ng Makina',
          body: 'Kung may makitang nag-expire na produkto sa makina, i-flag ito dito.',
        },
        {
          targetId: 'profile',
          tooltipPosition: 'top',
          title: 'Profile',
          body: 'Mag-sign out o i-restart ang tour mula dito.',
        },
        {
          targetId: 'todays-route',
          tooltipPosition: 'bottom',
          title: 'Handa na kayo!',
          body: 'Ang dashboard ay palaging nagpapakita ng pinakamahalagang gawain muna.',
        },
      ],
      'Susunod →',
      'Laktawan',
      'Magsimula ✓'
    ),
    pageTours: {
      packing: wSteps(
        [
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'Mga makina ngayon',
            body: 'Bawat row ay isang makina. Ipinapakita ang pag-usad ng packing.',
          },
          {
            targetId: 'packing-status',
            tooltipPosition: 'right',
            title: 'Status ng packing',
            body: 'Berde = fully packed. Kulay abo = hindi pa nagsisimula.',
          },
          {
            targetId: 'packing-list',
            tooltipPosition: 'bottom',
            title: 'Sa loob ng makina',
            body: 'I-tap para buksan ang shelf details. I-tick ang bawat produkto.',
          },
        ],
        'Susunod →',
        'Laktawan',
        'Magsimula ✓'
      ),
      dispatching: wSteps(
        [
          {
            targetId: 'dispatch-photos',
            tooltipPosition: 'bottom',
            title: 'Kumuha ng larawan',
            body: 'Kumuha ng larawan bago at pagkatapos mag-load. Pinapalitan nito ang WhatsApp.',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'Kumpirmahin ang bawat produkto',
            body: 'I-tick ang bawat slot habang ini-load mo sa makina.',
          },
          {
            targetId: 'dispatch-lines',
            tooltipPosition: 'top',
            title: 'Mag-iwan ng komento',
            body: 'Kung may pagkakaiba sa plano, magdagdag ng tala sa comment field.',
          },
        ],
        'Susunod →',
        'Laktawan',
        'Magsimula ✓'
      ),
      inventory: wSteps(
        [
          {
            targetId: 'inventory-filters',
            tooltipPosition: 'bottom',
            title: 'I-filter at i-group',
            body: 'Hanapin ang mga item na malapit nang mag-expire.',
          },
          {
            targetId: 'inventory-list',
            tooltipPosition: 'top',
            title: 'I-tap para i-edit',
            body: 'I-update ang dami, lokasyon, o markahan bilang inactive.',
          },
        ],
        'Susunod →',
        'Laktawan',
        'Magsimula ✓'
      ),
      tasks: wSteps(
        [
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'Mga gawain sa supplier',
            body: 'Nalilikha ang mga gawaing ito kapag kailangang kolektahin ang PO.',
          },
          {
            targetId: 'task-card',
            tooltipPosition: 'bottom',
            title: 'Kumpirmahin ang binili',
            body: 'I-tap ang gawain. Piliin ang resulta para sa bawat item.',
          },
        ],
        'Susunod →',
        'Laktawan',
        'Magsimula ✓'
      ),
    },
  },
}
