enum OnboardingIntent {
  fleetOwner('fleet_owner', 'Sou dono de uma frota'),
  driver('driver', 'Sou motorista'),
  guardian('guardian', 'Sou responsável por um aluno'),
  adultStudent('adult_student', 'Sou aluno maior de idade');

  const OnboardingIntent(this.apiValue, this.label);

  final String apiValue;
  final String label;
}
