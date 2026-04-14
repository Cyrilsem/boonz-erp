export interface Machine {
  machine_id: string;
  official_name: string;
  pod_number: string | null;
  machine_number: string | null;
  serial_number: string | null;
  status: string | null;
  include_in_refill: boolean;
  venue_group: string;
  pod_location: string | null;
  pod_address: string | null;
  location_type: string | null;
  freezone_location: boolean | null;
  latitude: number | null;
  longitude: number | null;
  building_id: string | null;
  previous_location: string | null;
  repurposed_at: string | null;
  installation_date: string | null;
  cabinet_count: number | null;
  source_of_supply: string | null;
  shipment_batch_nbr: string | null;
  notes: string | null;
  trade_license_number: string | null;
  permit_issue_date: string | null;
  permit_expiry_date: string | null;
  permit_status: string | null;
  contact_person: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  contract_signed: boolean | null;
  adyen_unique_terminal_id: string | null;
  adyen_permanent_terminal_id: string | null;
  adyen_status: string | null;
  adyen_inventory_in_store: string | null;
  adyen_store_code: string | null;
  adyen_store_description: string | null;
  adyen_fridge_assigned: string | null;
  micron_app_id: string | null;
  app_version: string | null;
  micron_version: string | null;
  payment_terminal_installed: boolean | null;
  payment_micron_bo_setup: boolean | null;
  payment_adyen_store_created: boolean | null;
  payment_connect_store_terminal: boolean | null;
  payment_general_ui_updated: boolean | null;
  payment_pos_hide_button: boolean | null;
  payment_app_deployed: boolean | null;
  payment_app_deployed_terminal: boolean | null;
  payment_kiosk_mode: boolean | null;
  payment_fan_test: boolean | null;
  hw_compressor_ok: boolean | null;
  hw_calibration_ok: boolean | null;
  hw_door_spring_ok: boolean | null;
  hw_test_successful: boolean | null;
  wifi_network_name: string | null;
  wifi_mac_address: string | null;
  wifi_device_hostname: string | null;
  created_at: string | null;
  updated_at: string | null;
}

export interface SimCard {
  sim_id: string;
  sim_ref: string | null;
  sim_serial: string | null;
  sim_code: string | null;
  sim_date: string | null;
  sim_renewal: string | null;
  contact_number: string | null;
  puk1: string | null;
  puk2: string | null;
  machine_id: string | null;
  machine_name: string | null;
  is_active: boolean | null;
  paid_by: string | null;
  notes: string | null;
  created_at: string | null;
  updated_at: string | null;
}

export const PAYMENT_FIELDS: { key: keyof Machine; label: string }[] = [
  { key: "payment_terminal_installed", label: "Terminal Installed" },
  { key: "payment_micron_bo_setup", label: "Micron BO Setup" },
  { key: "payment_adyen_store_created", label: "Adyen Store Created" },
  { key: "payment_connect_store_terminal", label: "Connect Store & Terminal" },
  { key: "payment_general_ui_updated", label: "General UI Updated" },
  { key: "payment_pos_hide_button", label: "POS Hide Button" },
  { key: "payment_app_deployed", label: "App Deployed (BO/Adyen)" },
  { key: "payment_app_deployed_terminal", label: "App Deployed (Terminal)" },
  { key: "payment_kiosk_mode", label: "Kiosk Mode" },
  { key: "payment_fan_test", label: "Fan Test" },
];

export const HW_FIELDS: { key: keyof Machine; label: string }[] = [
  { key: "hw_compressor_ok", label: "Compressor OK" },
  { key: "hw_calibration_ok", label: "Calibration OK" },
  { key: "hw_door_spring_ok", label: "Door Spring & Auto-Close OK" },
  { key: "hw_test_successful", label: "Test Successful" },
];
