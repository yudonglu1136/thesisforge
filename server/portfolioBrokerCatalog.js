// A capability is not evidence that a user account has connected successfully.
export function portfolioBrokerCatalog() {
  return {
    access: 'read_only',
    brokers: [
      {id: 'ibkr_flex', name: 'Interactive Brokers', available: true,
        connectionMethod: 'flex_report', status: 'available'},
      {id: 'questrade', name: 'Questrade', available: true,
        connectionMethod: 'personal_api_authorization', status: 'setup_required'},
      {id: 'futu', name: 'Futu / moomoo', available: true,
        connectionMethod: 'local_opend_connector', status: 'setup_required'},
    ],
  };
}
