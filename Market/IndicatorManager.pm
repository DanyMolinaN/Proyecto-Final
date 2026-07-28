package Market::IndicatorManager;

# =============================================================================
# Market::IndicatorManager
# -----------------------------------------------------------------------------
# Capa de INDICADORES. Gestiona multiples indicadores tecnicos de forma
# desacoplada: permite registrarlos, actualizarlos y consultarlos sin acoplar
# su logica al sistema de render. Responsabilidad unica: orquestar indicadores.
#
# IMPORTANTE: El orden de registro determina el orden de calculo en
# rebuild_all() y update_last(). Registrar los indicadores en el orden
# correcto de dependencias (ej: ATR antes que Liquidity).
# =============================================================================

use strict;
use warnings;

# new() -> $self
# Inicializa el contenedor de indicadores (vacio).
sub new {
    my ($class) = @_;
    my $self = {
        indicators => {},   # nombre -> objeto indicador
        _order     => [],   # lista de nombres en orden de registro
    };
    bless $self, $class;
    return $self;
}

# register($name, $indicator, %opts)
# opts:
#   lazy_tf => 1  — no se recalcula en rebuild_all salvo force=>1
#                   (herramientas opcionales / Tools Extra desactivadas)
sub register {
    my ($self, $name, $indicator, %opts) = @_;
    return unless defined $name && $indicator;

    unless (exists $self->{indicators}{$name}) {
        push @{ $self->{_order} }, $name;
    }
    $self->{indicators}{$name} = $indicator;
    $self->{_lazy_tf}{$name} = 1 if $opts{lazy_tf};
}

# rebuild_all($market_data, %opts)
# opts:
#   force => 1           — incluye indicadores lazy_tf
#   only  => \@names     — solo estos nombres
#   skip  => \@names     — excluye estos nombres
#   include_lazy => 1    — alias de force para lazy_tf
sub rebuild_all {
    my ($self, $market_data, %opts) = @_;
    return unless $market_data;

    my %only = map { $_ => 1 } @{ $opts{only}  || [] };
    my %skip = map { $_ => 1 } @{ $opts{skip}  || [] };
    my $force_lazy = $opts{force} || $opts{include_lazy};

    for my $name (@{ $self->{_order} }) {
        next if %only && !$only{$name};
        next if $skip{$name};
        # Herramientas lazy (David): omitir en cambio de TF si no se fuerza
        next if !$force_lazy && $self->{_lazy_tf}{$name};

        my $indicator = $self->{indicators}{$name};
        next unless $indicator;
        $indicator->reset() if $indicator->can('reset');
        if ($indicator->can('recompute')) {
            $indicator->recompute($market_data);
        }
        elsif ($indicator->can('update_at_index')) {
            # Fallback: ATR y similares sin recompute()
            my $size = $market_data->size // 0;
            for my $i (0 .. $size - 1) {
                $indicator->update_at_index($market_data, $i);
            }
        }
    }
}

# rebuild_one($name, $market_data) — recalcula un indicador concreto (lazy on-demand)
sub rebuild_one {
    my ($self, $name, $market_data) = @_;
    return unless $market_data && defined $name;
    my $indicator = $self->{indicators}{$name};
    return unless $indicator;
    $indicator->reset() if $indicator->can('reset');
    if ($indicator->can('recompute')) {
        $indicator->recompute($market_data);
    }
    elsif ($indicator->can('update_at_index')) {
        my $size = $market_data->size // 0;
        for my $i (0 .. $size - 1) {
            $indicator->update_at_index($market_data, $i);
        }
    }
    return $indicator;
}
# update_last($market_data)
# Actualiza todos los indicadores con la ultima vela (calculo incremental).
# Respeta el orden de registro para garantizar dependencias.
sub update_last {
    my ($self, $market_data) = @_;
    return unless $market_data;
    for my $name (@{ $self->{_order} }) {
        my $indicator = $self->{indicators}{$name};
        next unless $indicator;
        $indicator->update_last($market_data) if $indicator->can('update_last');
    }
}

# get($name) -> $indicator | undef
# Devuelve el indicador registrado con ese nombre.
sub get {
    my ($self, $name) = @_;
    return $self->{indicators}{$name};
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
# Respeta el orden de registro.
sub reset_all {
    my ($self) = @_;
    for my $name (@{ $self->{_order} }) {
        my $indicator = $self->{indicators}{$name};
        next unless $indicator;
        $indicator->reset() if $indicator->can('reset');
    }
}

# names() -> @names
# Devuelve la lista de nombres de indicadores en orden de registro.
sub names {
    my ($self) = @_;
    return @{ $self->{_order} };
}

1;
