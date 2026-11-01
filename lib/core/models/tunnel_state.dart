/// Состояние туннеля, как его видит интерфейс.
enum VpnStatus {
  /// Туннель не поднят.
  disconnected,

  /// Идёт подготовка и запуск ядра.
  connecting,

  /// Ядро поднято, трафик идёт через туннель.
  connected,

  /// Идёт остановка.
  disconnecting,

  /// Туннель упал, в [TunnelState.error] — причина.
  failed;

  bool get isBusy =>
      this == VpnStatus.connecting || this == VpnStatus.disconnecting;

  bool get isActive => this == VpnStatus.connected;
}

/// Текущее состояние туннеля с подробностями.
class TunnelState {
  const TunnelState({
    this.status = VpnStatus.disconnected,
    this.error = '',
    this.startedAt,
    this.serverName = '',
  });

  final VpnStatus status;

  /// Текст последней ошибки; пусто, если ошибок не было.
  final String error;

  /// Момент подключения — по нему считается длительность сессии.
  final DateTime? startedAt;

  /// Имя выбранного сервера.
  final String serverName;

  TunnelState copyWith({
    VpnStatus? status,
    String? error,
    DateTime? startedAt,
    String? serverName,
    bool clearStartedAt = false,
  }) {
    return TunnelState(
      status: status ?? this.status,
      error: error ?? this.error,
      // `null` означает «оставить как есть», поэтому обнуление отдельным
      // флагом: иначе длительность старой сессии пережила бы переподключение.
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      serverName: serverName ?? this.serverName,
    );
  }

  /// Длительность текущей сессии.
  Duration get connectedFor {
    final start = startedAt;
    if (start == null || status != VpnStatus.connected) {
      return Duration.zero;
    }
    return DateTime.now().difference(start);
  }
}
