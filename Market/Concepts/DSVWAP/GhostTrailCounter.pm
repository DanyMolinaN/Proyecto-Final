package Market::Concepts::DSVWAP::GhostTrailCounter;

use strict;
use warnings;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::GhostTrailCounter
# Responsabilidad: Cuenta los rastros históricos dejados por los fantasmas
# (GhostTrailEvent) relativos a cada aparición (AnchorChangedEvent).
# Funciona en modo incremental (para el Chart) y modo batch (para la tabla ML).
# =============================================================================

sub new {
    my ($class, $event_bus, $cache) = @_;
    my $self = {
        bus    => $event_bus,
        cache  => $cache,
        
        # Almacenará los rastros acumulados de la iteración en vivo
        current_trails => [],
        
        # Almacenará el registro histórico para modo batch
        history_appearances => [],
        history_trails      => [],
    };
    bless $self, $class;

    $self->{bus}->subscribe('AnchorChangedEvent', sub { $self->_on_anchor_changed(@_) });
    $self->{bus}->subscribe('GhostTrailEvent',    sub { $self->_on_ghost_trail(@_) });

    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{current_trails} = [];
    $self->{history_appearances} = [];
    $self->{history_trails} = [];
    $self->{cache}->{ghost_trails} = $self->{current_trails};
}

sub _on_anchor_changed {
    my ($self, $event) = @_;
    
    # Cada vez que cambia el ancla, limpiamos los rastros "vivos" del overlay
    $self->{current_trails} = [];
    $self->{cache}->{ghost_trails} = $self->{current_trails};

    # Registramos la aparición para el modo batch
    push @{$self->{history_appearances}}, {
        index => $event->{index},
        price => $event->{price},
        dir   => $event->{direction}, # 1 Low, -1 High
    };
}

sub _on_ghost_trail {
    my ($self, $event) = @_;
    
    # Guardamos en la memoria viva para el Overlay (se borra con cada ancla)
    push @{$self->{current_trails}}, $event;
    $self->{cache}->{ghost_trails} = $self->{current_trails};
    
    # Guardamos en el historial completo para el modo batch
    push @{$self->{history_trails}}, $event;
}

# -----------------------------------------------------------------------------
# Modo batch (para entrenamiento ML)
#
# Para cada aparición en índice A, cuenta todos los GhostTrailEvents cuyo
# bar-index caiga estrictamente en (A, A+N] para N ∈ {3, 5, 10, 15}.
#
# MODELO CORRECTO: el rail '1' del Pine ocurre cuando la vela ACTUAL (barra
# confirmada) es el nuevo extremo del fantasma. No importa a qué ancla
# "pertenece" el trail — lo que interesa es cuántos rastros aparecen en la
# ventana de N velas 1m POSTERIOR a la aparición del fantasma.
# Ejemplo: aparición en bar 500 → trails_3m = # trails con index ∈ {501,502,503}
#
# Implementación O(T log T + A*log T): construimos un array ordenado de índices
# de trail y usamos búsqueda binaria para contar en cada ventana.
# -----------------------------------------------------------------------------
sub count_trails_batch {
    my ($self) = @_;

    # Construir array ordenado de bar-indices de trails (puede haber duplicados
    # si en la misma barra hubo múltiples cambios de extremo, aunque es raro).
    my @trail_indices = sort { $a <=> $b }
                        map  { $_->{index} }
                        @{ $self->{history_trails} };

    my @results;

    for my $app (@{ $self->{history_appearances} }) {
        my $a = $app->{index};

        # Contamos trails en (a, a+N] con búsqueda binaria (lower/upper bound).
        # _count_in_range($lo_excl, $hi_incl, \@sorted) = # elementos en (lo, hi].
        my $c_3  = _count_in_range($a, $a + 3,  \@trail_indices);
        my $c_5  = _count_in_range($a, $a + 5,  \@trail_indices);
        my $c_10 = _count_in_range($a, $a + 10, \@trail_indices);
        my $c_15 = _count_in_range($a, $a + 15, \@trail_indices);

        # Verificación de monotonía (invariante garantizado por construcción
        # pero útil para detectar bugs en el futuro).
        if (!($c_3 <= $c_5 && $c_5 <= $c_10 && $c_10 <= $c_15)) {
            warn "BUG DETECTADO: Monotonia rota para ancla en index $a. " .
                 "Conteos: 3m=$c_3, 5m=$c_5, 10m=$c_10, 15m=$c_15\n";
        }

        push @results, {
            anchor_index => $a,
            anchor_price => $app->{price},
            anchor_dir   => $app->{dir},
            trails_3m    => $c_3,
            trails_5m    => $c_5,
            trails_10m   => $c_10,
            trails_15m   => $c_15,
        };
    }

    return \@results;
}

# _count_in_range($lo_excl, $hi_incl, \@sorted_ints)
# Retorna el número de elementos en el array ordenado que caen en (lo, hi].
# Usa búsqueda binaria para O(log n).
sub _count_in_range {
    my ($lo, $hi, $arr) = @_;
    return 0 unless @$arr;

    # lower_bound: primer índice con arr[i] > lo
    my ($l, $r) = (0, scalar @$arr);
    while ($l < $r) {
        my $m = int(($l + $r) / 2);
        $arr->[$m] <= $lo ? ($l = $m + 1) : ($r = $m);
    }
    my $left = $l;

    # upper_bound: primer índice con arr[i] > hi
    ($l, $r) = (0, scalar @$arr);
    while ($l < $r) {
        my $m = int(($l + $r) / 2);
        $arr->[$m] <= $hi ? ($l = $m + 1) : ($r = $m);
    }
    my $right = $l;

    return $right - $left;
}

1;
