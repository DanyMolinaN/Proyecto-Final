package Market::Core::TimeframeManager;

# =============================================================================
# Market::Core::TimeframeManager
# Coordina el cambio de temporalidad entre MarketData, indicadores y ChartEngine.
# =============================================================================

use strict;
use warnings;

use Market::MarketData;

sub new {
    my ($class, %args) = @_;
    my $self = {
        initialized => 0,
        active_tf   => undef,
        selected_tf => undef,
        visible_tf  => undef,
        available   => [qw(1m 5m 15m 1H 2H 4H 1D 1W)],
        %args,
    };
    bless $self, $class;
    return $self;
}

sub initialize {
    my ($self, $tf) = @_;
    $self->{initialized} = 1;
    $self->set_active($tf) if defined $tf;
    return $self;
}

sub set_active {
    my ($self, $tf) = @_;
    return undef unless defined $tf;
    $self->{active_tf}   = $tf;
    $self->{selected_tf} = $tf;
    $self->{visible_tf}  = $tf;
    return $self->{active_tf};
}

sub is_supported {
    my ($self, $tf) = @_;
    return 0 unless defined $tf;
    return Market::MarketData->tf_minutes($tf) ? 1 : 0;
}

sub list_available {
    my ($self) = @_;
    return [ @{ $self->{available} || [] } ];
}

sub get_active { my ($self) = @_; return $self->{active_tf}; }
sub current    { my ($self) = @_; return $self->{active_tf}; }

sub set {
    my ($self, $tf) = @_;
    return $self->set_active($tf);
}

sub available { my ($self) = @_; return $self->list_available(); }

sub can_change {
    my ($self, $tf) = @_;
    return 0 unless defined $tf;
    return $self->is_supported($tf);
}

sub changed {
    my ($self, $tf) = @_;
    return 0 unless defined $tf;
    return 1 if !defined $self->{active_tf} || $self->{active_tf} ne $tf;
    return 0;
}

# apply($market_data, $tf, \%opts) -> $ok
# Cambia la temporalidad activa en MarketData y actualiza el estado interno.
sub apply {
    my ($self, $market_data, $tf, $opts) = @_;
    $opts ||= {};
    return 0 unless $market_data && $self->can_change($tf);

    $market_data->set_timeframe($tf);
    return 0 unless ($market_data->size || 0) > 0;

    $self->set_active($tf);
    return 1;
}

sub reset {
    my ($self) = @_;
    $self->{active_tf} = undef;
    return $self;
}

sub dispose {
    my ($self) = @_;
    $self->{initialized} = 0;
    $self->{active_tf}   = undef;
    return $self;
}

sub is_initialized {
    my ($self) = @_;
    return $self->{initialized} ? 1 : 0;
}

1;
