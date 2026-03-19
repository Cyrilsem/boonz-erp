export type Language = 'en' | 'hi' | 'ta' | 'ml' | 'tl'

export interface TourStep {
  title: string
  body: string
  buttonNext: string
  buttonSkip: string
  buttonDone: string
}

export interface TranslationSet {
  languagePicker: {
    title: string
    subtitle: string
    confirm: string
  }
  warehouseTour: TourStep[]
  driverTour: TourStep[]
}

// ─── Helper ───────────────────────────────────────────────────────────────────

function wSteps(
  steps: { title: string; body: string }[],
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
          title: 'Welcome to Boonz',
          body: "This is your operations app. Let's take a 2-minute tour to get you started.",
        },
        {
          title: 'Daily Refills',
          body: "This section shows today's packing progress. You can see how many machines need to be packed, picked up, and dispatched.",
        },
        {
          title: 'Packing',
          body: "Tap Packing to open today's machines. Tick each shelf slot as you pack it. Stock levels are colour-coded — green means plenty, red means low or expired.",
        },
        {
          title: 'Procurement',
          body: 'Use this section to manage purchase orders. You can create new orders, track pending deliveries, and receive stock.',
        },
        {
          title: 'Receiving',
          body: 'When a delivery arrives, tap Receiving. Find the PO, enter what you actually received and the expiry dates. This updates your warehouse stock automatically.',
        },
        {
          title: 'Inventory',
          body: 'This section shows your full warehouse stock. Use the expiry alerts to act quickly on items expiring soon. Run an Inventory Control regularly to keep records accurate.',
        },
        {
          title: 'Machine Stock Expiry',
          body: 'These cards show expired or expiring products inside the machines. Tap to see which machines need attention — grouped by machine for easy action.',
        },
        {
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
          title: 'Welcome to Boonz',
          body: "This is your daily operations app. Let's take a quick tour.",
        },
        {
          title: "Today's Route",
          body: 'This section shows your machines for today and your progress across packing, pickup, and dispatch.',
        },
        {
          title: 'Pickup',
          body: 'Before you drive out, check the Pickup section. Confirm you have collected all packed boxes from the warehouse.',
        },
        {
          title: 'Dispatching',
          body: 'At each machine, open Dispatching. Tick each item as you load it into the machine. Take a before and after photo — this replaces WhatsApp photos.',
        },
        {
          title: 'Tasks',
          body: 'Check here for any supplier collection tasks. For each task, tap to see the product list and confirm what you purchased and in what quantity.',
        },
        {
          title: 'Machine Stock',
          body: 'If you see an expired product in a machine, flag it here. Your request goes to the warehouse team to confirm the update.',
        },
      ],
      'Next →',
      'Skip tour',
      'Get started ✓'
    ),
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
          title: 'Boonz में आपका स्वागत है',
          body: 'यह आपका ऑपरेशन ऐप है। शुरुआत के लिए 2 मिनट का टूर लेते हैं।',
        },
        {
          title: 'दैनिक रिफिल',
          body: 'यह सेक्शन आज की पैकिंग प्रगति दिखाता है।',
        },
        {
          title: 'पैकिंग',
          body: 'पैकिंग खोलें और हर शेल्फ स्लॉट पैक होने पर टिक करें।',
        },
        {
          title: 'खरीद',
          body: 'यहाँ से नए ऑर्डर बनाएं और डिलीवरी ट्रैक करें।',
        },
        {
          title: 'प्राप्ति',
          body: 'डिलीवरी आने पर Receiving खोलें और स्टॉक अपडेट करें।',
        },
        {
          title: 'इन्वेंटरी',
          body: 'पूरे वेयरहाउस स्टॉक की जानकारी यहाँ मिलेगी।',
        },
        {
          title: 'मशीन स्टॉक',
          body: 'मशीनों में एक्सपायर हो रहे प्रोडक्ट यहाँ दिखते हैं।',
        },
        {
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
          title: 'Boonz में आपका स्वागत है',
          body: 'यह आपका दैनिक ऑपरेशन ऐप है।',
        },
        {
          title: 'आज का रूट',
          body: 'यहाँ आज की मशीनें और आपकी प्रगति दिखती है।',
        },
        {
          title: 'पिकअप',
          body: 'गाड़ी निकलने से पहले वेयरहाउस से पैक बॉक्स कन्फर्म करें।',
        },
        {
          title: 'डिस्पैचिंग',
          body: 'हर मशीन पर आइटम लोड करते समय टिक करें। फोटो भी लें।',
        },
        {
          title: 'टास्क',
          body: 'सप्लायर से सामान लाने के टास्क यहाँ दिखते हैं।',
        },
        {
          title: 'मशीन स्टॉक',
          body: 'मशीन में एक्सपायर प्रोडक्ट दिखे तो यहाँ फ्लैग करें।',
        },
      ],
      'आगे →',
      'टूर छोड़ें',
      'शुरू करें ✓'
    ),
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
          title: 'Boonz-க்கு வரவேற்கிறோம்',
          body: 'இது உங்கள் செயல்பாட்டு ஆப். 2 நிமிட சுற்றுப்பயணம் மேற்கொள்வோம்.',
        },
        {
          title: 'தினசரி நிரப்புதல்',
          body: 'இன்றைய பேக்கிங் முன்னேற்றம் இங்கே காட்டப்படுகிறது.',
        },
        {
          title: 'பேக்கிங்',
          body: 'பேக்கிங் திறந்து ஒவ்வொரு அலமாரியையும் டிக் செய்யுங்கள்.',
        },
        {
          title: 'கொள்முதல்',
          body: 'புதிய ஆர்டர்கள் உருவாக்கி டெலிவரி கண்காணிக்கவும்.',
        },
        {
          title: 'பெறுதல்',
          body: 'டெலிவரி வந்தால் Receiving திறந்து ஸ்டாக் புதுப்பிக்கவும்.',
        },
        {
          title: 'சரக்கு',
          body: 'முழு கிடங்கு ஸ்டாக் தகவல் இங்கே கிடைக்கும்.',
        },
        {
          title: 'இயந்திர ஸ்டாக்',
          body: 'இயந்திரங்களில் காலாவதியான பொருட்கள் இங்கே காட்டப்படும்.',
        },
        {
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
          title: 'Boonz-க்கு வரவேற்கிறோம்',
          body: 'இது உங்கள் தினசரி செயல்பாட்டு ஆப்.',
        },
        {
          title: 'இன்றைய பாதை',
          body: 'இன்றைய இயந்திரங்களும் முன்னேற்றமும் இங்கே தெரியும்.',
        },
        {
          title: 'பிக்கப்',
          body: 'கிளம்புவதற்கு முன் கிடங்கிலிருந்து பேக் பெட்டிகளை உறுதிப்படுத்தவும்.',
        },
        {
          title: 'அனுப்புதல்',
          body: 'ஒவ்வொரு இயந்திரிலும் பொருட்களை ஏற்றும்போது டிக் செய்யுங்கள்.',
        },
        {
          title: 'பணிகள்',
          body: 'சப்ளையரிடமிருந்து சேகரிக்கும் பணிகள் இங்கே காட்டப்படும்.',
        },
        {
          title: 'இயந்திர ஸ்டாக்',
          body: 'இயந்திரில் காலாவதியான பொருள் தெரிந்தால் இங்கே கொடியிடவும்.',
        },
      ],
      'அடுத்து →',
      'தவிர்',
      'தொடங்குங்கள் ✓'
    ),
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
          title: 'Boonz-ലേക്ക് സ്വാഗതം',
          body: 'ഇത് നിങ്ങളുടെ ഓപ്പറേഷൻ ആപ്പ് ആണ്. 2 മിനിറ്റ് ടൂർ ആരംഭിക്കാം.',
        },
        {
          title: 'ദൈനംദിന റീഫിൽ',
          body: 'ഇന്നത്തെ പാക്കിംഗ് പുരോഗതി ഇവിടെ കാണാം.',
        },
        {
          title: 'പാക്കിംഗ്',
          body: 'പാക്കിംഗ് തുറന്ന് ഓരോ ഷെൽഫ് സ്ലോട്ടും ടിക് ചെയ്യൂ.',
        },
        {
          title: 'സംഭരണം',
          body: 'പുതിയ ഓർഡറുകൾ സൃഷ്ടിക്കാനും ഡെലിവറി ട്രാക്ക് ചെയ്യാനും.',
        },
        {
          title: 'സ്വീകരണം',
          body: 'ഡെലിവറി വന്നാൽ Receiving തുറന്ന് സ്റ്റോക്ക് അപ്ഡേറ്റ് ചെയ്യൂ.',
        },
        {
          title: 'ഇൻവെന്ററി',
          body: 'പൂർണ്ണ വെയർഹൗസ് സ്റ്റോക്ക് വിവരങ്ങൾ ഇവിടെ കിട്ടും.',
        },
        {
          title: 'മെഷീൻ സ്റ്റോക്ക്',
          body: 'മെഷീനുകളിൽ കാലഹരണപ്പെട്ട ഉൽപ്പന്നങ്ങൾ ഇവിടെ കാണാം.',
        },
        {
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
          title: 'Boonz-ലേക്ക് സ്വാഗതം',
          body: 'ഇത് നിങ്ങളുടെ ദൈനംദിന ഓപ്പറേഷൻ ആപ്പ് ആണ്.',
        },
        {
          title: 'ഇന്നത്തെ റൂട്ട്',
          body: 'ഇന്നത്തെ മെഷീനുകളും പുരോഗതിയും ഇവിടെ കാണാം.',
        },
        {
          title: 'പിക്കപ്പ്',
          body: 'പുറപ്പെടുന്നതിന് മുമ്പ് വെയർഹൗസിൽ നിന്ന് പ്യാക്ക് ചെയ്ത ബോക്സുകൾ സ്ഥിരീകരിക്കൂ.',
        },
        {
          title: 'ഡിസ്പാച്ചിംഗ്',
          body: 'ഓരോ മെഷീനിലും ഇനങ്ങൾ ലോഡ് ചെയ്യുമ്പോൾ ടിക് ചെയ്യൂ.',
        },
        {
          title: 'ടാസ്‌ക്കുകൾ',
          body: 'സപ്ലയർ കളക്ഷൻ ടാസ്‌ക്കുകൾ ഇവിടെ കാണാം.',
        },
        {
          title: 'മെഷീൻ സ്റ്റോക്ക്',
          body: 'മെഷീനിൽ കാലഹരണപ്പെട്ട ഉൽപ്പന്നം കണ്ടാൽ ഇവിടെ ഫ്ലാഗ് ചെയ്യൂ.',
        },
      ],
      'അടുത്തത് →',
      'ഒഴിവാക്കൂ',
      'ആരംഭിക്കൂ ✓'
    ),
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
          title: 'Maligayang pagdating sa Boonz',
          body: 'Ito ang iyong operations app. Magsimula tayo ng 2-minutong tour.',
        },
        {
          title: 'Araw-araw na Refill',
          body: "Ipinapakita ng seksyong ito ang pag-usad ng packing ngayon.",
        },
        {
          title: 'Packing',
          body: 'Buksan ang Packing at i-tick ang bawat shelf slot pagkatapos i-pack.',
        },
        {
          title: 'Pagbili',
          body: 'Gumawa ng bagong orders at subaybayan ang mga delivery dito.',
        },
        {
          title: 'Pagtanggap',
          body: 'Kapag dumating ang delivery, buksan ang Receiving at i-update ang stock.',
        },
        {
          title: 'Imbentaryo',
          body: 'Makikita dito ang buong impormasyon ng stock sa bodega.',
        },
        {
          title: 'Stock ng Makina',
          body: 'Ang mga produktong nag-expire sa mga makina ay makikita dito.',
        },
        {
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
          title: 'Maligayang pagdating sa Boonz',
          body: "Ito ang iyong pang-araw-araw na operations app.",
        },
        {
          title: 'Ruta Ngayon',
          body: "Ipinapakita dito ang iyong mga makina ngayon at ang iyong pag-usad.",
        },
        {
          title: 'Pickup',
          body: 'Bago umalis, kumpirmahin na nakuha mo na ang mga naka-pack na kahon mula sa bodega.',
        },
        {
          title: 'Dispatching',
          body: 'Sa bawat makina, i-tick ang bawat item habang ini-load mo ito.',
        },
        {
          title: 'Mga Gawain',
          body: 'Tingnan dito ang mga gawaing pangongolekta mula sa supplier.',
        },
        {
          title: 'Stock ng Makina',
          body: "Kung may makitang nag-expire na produkto sa makina, i-flag ito dito.",
        },
      ],
      'Susunod →',
      'Laktawan',
      'Magsimula ✓'
    ),
  },
}
