package Market::Core::EngineRegistry;

# =============================================================================
# Market::Core::EngineRegistry
# -----------------------------------------------------------------------------
# Registro ordenado de motores de analisis. Soporta rebuild selectivo:
#   rebuild($md, only => \@names)     — solo esos (+ deps si want_fn)
#   rebuild($md, skip => \@names)     — todos excepto esos
#   rebuild($md, want  => sub {...})  — predicado por nombre
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class) = @_;
    my $self = {
        _engines => {},
        _order   => [],
        _cache   => {},
    };
    bless $self, $class;
    return $self;
}

sub register {
    my ($self, $name, $engine, %opts) = @_;
    return unless defined $name && $engine;

    unless (exists $self->{_engines}{$name}) {
        push @{ $self->{_order} }, $name;
    }
    $self->{_engines}{$name} = {
        engine => $engine,
        deps   => $opts{deps} || [],
        calc   => $opts{calc} || undef,
    };
}

sub get {
    my ($self, $name) = @_;
    my $entry = $self->{_engines}{$name};
    return $entry ? $entry->{engine} : undef;
}

sub get_cache {
    my ($self, $name) = @_;
    return defined $name ? $self->{_cache}{$name} : $self->{_cache};
}

# rebuild($market_data, %args) -> \%cache
# args especiales (no se pasan a engines):
#   only  => \@names
#   skip  => \@names
#   want  => sub { my ($name)=@_; return 1|0 }
#   keep_cache => 1  — no vaciar cache de engines omitidos (replay parcial)
sub rebuild {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $only = delete $args{only};
    my $skip = delete $args{skip};
    my $want = delete $args{want};
    my $keep = delete $args{keep_cache};

    my %only_set = map { $_ => 1 } @{ $only || [] };
    my %skip_set = map { $_ => 1 } @{ $skip || [] };

    # Si only está vacío pero se pasó only=>[], no calcular nada
    my $has_only = defined $only;

    my @to_run;
    for my $name (@{ $self->{_order} }) {
        next if $skip_set{$name};
        if ($has_only) {
            next unless $only_set{$name};
        }
        if ($want && ref $want eq 'CODE') {
            next unless $want->($name);
        }
        push @to_run, $name;
    }

    # Expandir dependencias hacia atras: si pedimos trend_channel, incluir
    # orderblock y smc_structure aunque no esten en only.
    if ($has_only || $want) {
        my %needed = map { $_ => 1 } @to_run;
        my $changed = 1;
        while ($changed) {
            $changed = 0;
            for my $name (keys %needed) {
                my $entry = $self->{_engines}{$name} or next;
                for my $d (@{ $entry->{deps} || [] }) {
                    next if $needed{$d};
                    $needed{$d} = 1;
                    $changed = 1;
                }
            }
        }
        # Reordenar segun _order
        @to_run = grep { $needed{$_} } @{ $self->{_order} };
    }

    $self->{_cache} = {} unless $keep;

    for my $name (@to_run) {
        my $entry = $self->{_engines}{$name};
        next unless $entry;

        my $engine = $entry->{engine};
        my @deps   = @{ $entry->{deps} || [] };

        $engine->reset() if $engine->can('reset');

        my $data;
        eval {
            if ($entry->{calc}) {
                $data = $entry->{calc}->(
                    $engine, $market_data, $self->{_cache}, %args
                );
            } elsif (@deps) {
                my %dep_data = map { $_ => $self->{_cache}{$_} } @deps;
                $data = $engine->calculate($market_data, %dep_data, %args);
            } else {
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

sub clear_cache {
    my ($self) = @_;
    $self->{_cache} = {};
    return $self;
}

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

sub names {
    my ($self) = @_;
    return @{ $self->{_order} };
}

1;
