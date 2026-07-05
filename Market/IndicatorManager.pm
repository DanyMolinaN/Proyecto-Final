package Market::IndicatorManager;

# =============================================================================
# Market::IndicatorManager
# -----------------------------------------------------------------------------
# Capa de INDICADORES. Gestiona multiples indicadores tecnicos de forma
# desacoplada: permite registrarlos, actualizarlos y consultarlos sin acoplar
# su logica al sistema de render. Responsabilidad unica: orquestar indicadores.
# =============================================================================

use strict;
use warnings;

# new() -> $self
# Inicializa el contenedor de indicadores (vacio).
sub new {
    my ($class) = @_;
    my $self = {
        indicators => {},
    };
    bless $self, $class;
    return $self;
}

# register($name, $indicator)
# Registra un indicador bajo un nombre. Permite extensibilidad.
sub register {
    my ($self, $name, $indicator) = @_;
    return unless defined $name && $indicator;
    $self->{indicators}->{$name} = $indicator;
}

# update_last($market_data)
# Actualiza todos los indicadores con la ultima vela (calculo incremental).
sub update_last {
    my ($self, $market_data) = @_;
    return unless $market_data;
    foreach my $name (keys %{ $self->{indicators} }) {
        my $indicator = $self->{indicators}->{$name};
        $indicator->update_last($market_data) if $indicator->can('update_last');
    }
}

# get($name) -> $indicator | undef
# Devuelve el indicador registrado con ese nombre.
sub get {
    my ($self, $name) = @_;
    return $self->{indicators}->{$name};
}

# rebuild_all($market_data)
# Recalcula todos los indicadores sobre la temporalidad activa.
# Siempre llama a reset() antes de recompute() para garantizar que no haya
# datos residuales de la temporalidad anterior, independientemente de si
# recompute() hace su propio reset o no.
sub rebuild_all {
    my ($self, $market_data) = @_;
    return unless $market_data;
    foreach my $name (keys %{ $self->{indicators} }) {
        my $indicator = $self->{indicators}->{$name};
        # Reset explicito garantizado antes de recompute: evita acumulacion
        # de datos entre temporalidades si recompute() no hace su propio reset.
        $indicator->reset() if $indicator->can('reset');
        $indicator->recompute($market_data) if $indicator->can('recompute');
    }
}

# slice_array($name, $start, $end) -> \@values
# Devuelve una porcion de los valores de un indicador, sincronizada con la
# ventana visible [start..end] en indices ABSOLUTOS de la temporalidad activa.
#
# NOTA sobre el offset del ATR:
# El ATR calcula su primer valor real despues de `period` velas de bootstrap
# (SMA), por lo que su array comienza en el indice (period - 1) de la serie
# de velas. slice_array aplica ese offset automaticamente: si $start = 100
# y el ATR tiene offset 13, extrae values[100-13 .. end-13].
sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $indicator = $self->get($name);
    return [] unless $indicator;
    my $values = $indicator->{values} || [];
    return [] unless @$values;

    # Calcula el offset del indicador respecto a la serie de velas.
    # Para ATR(14): el primer ATR corresponde a la vela 14 (indice 13),
    # por lo que hay 13 velas sin valor al inicio -> offset = period - 1.
    my $offset = 0;
    if ($indicator->can('get_offset')) {
        $offset = $indicator->get_offset();
    } elsif (defined $indicator->{period}) {
        $offset = $indicator->{period} - 1;
    }

    my $size = scalar @$values;
    my $adj_start = $start - $offset;
    my $adj_end   = $end   - $offset;

    $adj_start = 0        if $adj_start < 0;
    $adj_end   = $size - 1 if $adj_end   >= $size;
    return [] if $adj_start > $adj_end;

    my @slice = @$values[$adj_start .. $adj_end];
    return \@slice;
}

# reset_all()
# Reinicia todos los indicadores (util al cambiar de temporalidad).
sub reset_all {
    my ($self) = @_;
    foreach my $name (keys %{ $self->{indicators} }) {
        my $indicator = $self->{indicators}->{$name};
        $indicator->reset() if $indicator->can('reset');
    }
}

# names() -> @names
# Devuelve la lista de nombres de indicadores registrados.
sub names {
    my ($self) = @_;
    return keys %{ $self->{indicators} };
}

1;
