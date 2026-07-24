package Market::Core::EngineRegistry;

# =============================================================================
# Market::Core::EngineRegistry
# -----------------------------------------------------------------------------
# Registro ordenado de motores de analisis (engines) que producen datos para
# los overlays. Separa el calculo del render: los engines calculan datos sobre
# el dataset completo y guardan su resultado en cache; los overlays consumen
# esos datos sin recalcular nada.
#
# Patron de uso:
#   1. Registrar engines en orden de dependencias (via register()).
#   2. Llamar a rebuild($market_data, %args) al cambiar datos o temporalidad.
#   3. ChartEngine llama a get_cache() para alimentar los overlays.
#
# Dependencias de calculo (orden obligatorio):
#   atr -> liquidity -> smc_structure -> fvg -> orderblock -> ...
# =============================================================================

use strict;
use warnings;

# new() -> $self
sub new {
    my ($class) = @_;
    my $self = {
        _engines => {},    # nombre -> { engine => $obj, deps => \@names }
        _order   => [],    # nombres en orden de registro (= orden de calculo)
        _cache   => {},    # nombre -> datos calculados por ese engine
    };
    bless $self, $class;
    return $self;
}

# register($name, $engine, deps => \@dep_names)
# Registra un engine bajo un nombre. deps es opcional: lista de nombres de
# otros engines cuyos datos se pasan como argumento al calcular este engine.
# El orden de llamadas a register() determina el orden de calculo.
sub register {
    my ($self, $name, $engine, %opts) = @_;
    return unless defined $name && $engine;

    unless (exists $self->{_engines}{$name}) {
        push @{ $self->{_order} }, $name;
    }
    $self->{_engines}{$name} = {
        engine => $engine,
        deps   => $opts{deps} || [],
        calc   => $opts{calc} || undef,   # sub personalizado de calculo
    };
}

# get($name) -> $engine | undef
# Devuelve el objeto engine registrado bajo ese nombre.
sub get {
    my ($self, $name) = @_;
    my $entry = $self->{_engines}{$name};
    return $entry ? $entry->{engine} : undef;
}

# get_cache($name) -> $data | undef
# Devuelve los ultimos datos calculados por el engine con ese nombre.
# Si no se ha calculado aun, devuelve undef.
sub get_cache {
    my ($self, $name) = @_;
    return defined $name ? $self->{_cache}{$name} : $self->{_cache};
}

# rebuild($market_data, %args) -> \%cache
# Recalcula todos los engines registrados en orden.
# %args se pasa a cada engine->calculate() como argumentos extra.
# Los datos de engines anteriores (deps) se inyectan como argumentos
# adicionales cuando el engine tiene dependencias declaradas.
sub rebuild {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    $self->{_cache} = {};

    for my $name (@{ $self->{_order} }) {
        my $entry = $self->{_engines}{$name};
        next unless $entry;

        my $engine = $entry->{engine};
        my @deps   = @{ $entry->{deps} || [] };

        # Reset del engine antes de recalcular
        $engine->reset() if $engine->can('reset');

        my $data;
        eval {
            if ($entry->{calc}) {
                # Sub personalizado: recibe ($engine, $market_data, $cache, %args)
                $data = $entry->{calc}->(
                    $engine, $market_data, $self->{_cache}, %args
                );
            } elsif (@deps) {
                # Engine con dependencias: pasar datos de deps como args
                my %dep_data = map { $_ => $self->{_cache}{$_} } @deps;
                $data = $engine->calculate(
                    $market_data, %dep_data, %args
                );
            } else {
                # Engine sin dependencias declaradas
                $data = $engine->calculate($market_data, %args);
            }
        };
        if ($@) {
            warn "[EngineRegistry] Error calculando '$name': $@\n";
            $data = undef;
        }

        $self->{_cache}{$name} = $data;
    }

    return $self->{_cache};
}

# invalidate()
# Limpia la cache de todos los engines (fuerza recalculo en el proximo rebuild).
sub invalidate {
    my ($self) = @_;
    $self->{_cache} = {};
    for my $name (@{ $self->{_order} }) {
        my $entry = $self->{_engines}{$name};
        next unless $entry && $entry->{engine};
        $entry->{engine}->reset() if $entry->{engine}->can('reset');
    }
    return $self;
}

# names() -> @names
# Nombres de engines en orden de registro.
sub names {
    my ($self) = @_;
    return @{ $self->{_order} };
}

1;
