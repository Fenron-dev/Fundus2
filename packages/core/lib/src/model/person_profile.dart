/// Persönliche Zusatzdaten zu einer beteiligten Person.
///
/// Rollen und Werke bleiben in [work_people]. Dieses Profil enthält nur
/// Angaben, die zur Person selbst gehören und deshalb bibliotheksweit gelten.
final class PersonProfile {
  const PersonProfile({
    required this.id,
    required this.displayName,
    this.imagePath,
    this.notes = '',
    this.externalIds = const {},
  });

  final String id;
  final String displayName;
  final String? imagePath;
  final String notes;
  final Map<String, String> externalIds;
}
