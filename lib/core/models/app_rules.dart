/// Как приложения попадают в туннель.
enum AppsMode {
  /// Весь трафик — в туннель.
  all,

  /// В туннель только выбранные приложения.
  allow,

  /// Все приложения — в туннель, кроме выбранных.
  deny;

  /// Человеческое название режима.
  String get label => switch (this) {
        AppsMode.all => 'Все приложения',
        AppsMode.allow => 'Только выбранные',
        AppsMode.deny => 'Кроме выбранных',
      };

  /// Короткое пояснение под названием.
  String get hint => switch (this) {
        AppsMode.all => 'Весь трафик идёт через туннель',
        AppsMode.allow => 'В туннель попадают только отмеченные приложения',
        AppsMode.deny => 'Отмеченные приложения идут мимо туннеля',
      };

  static AppsMode fromName(String? name) => switch (name) {
        'allow' => AppsMode.allow,
        'deny' => AppsMode.deny,
        _ => AppsMode.all,
      };
}
