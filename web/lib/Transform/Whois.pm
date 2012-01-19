package Transform::Whois;
use Moose;
use Data::Dumper;
use CHI;
use AnyEvent::HTTP;
use Socket;
use JSON;
extends 'Transform';
our $Name = 'Whois';
# Whois transform plugin
has 'name' => (is => 'rw', isa => 'Str', required => 1, default => $Name);
has 'cache' => (is => 'rw', isa => 'Object', required => 1);
has 'cv' => (is => 'rw', isa => 'Object');

#sub BUILDARGS {
#	my $class = shift;
#	my $params = $class->SUPER::BUILDARGS(@_);
#	$params->{cv} = AnyEvent->condvar;
#	return $params;
#}

sub BUILD {
	my $self = shift;
	
	foreach my $datum (@{ $self->data }){
		$datum->{transforms}->{whois} = {};
		
		$self->cv(AnyEvent->condvar);
		$self->cv->begin;
		foreach my $key (keys %{ $datum }){
			if ($key eq 'srcip' or $key eq 'dstip'){
				$datum->{transforms}->{whois}->{$key} = {};
				$self->_lookup($datum, $key, $datum->{$key});
			}
		}
		
		$self->cv->end;
		$self->cv->recv;
		
		foreach my $key qw(srcip dstip){
			if ($datum->{transforms}->{whois}->{$key} and $datum->{transforms}->{whois}->{$key}->{is_local}){
				delete $datum->{transforms}->{whois}->{$key};
#				$self->log->debug('transform: ' . Dumper($datum->{transforms}->{whois}->{$key}));
#				foreach my $field (keys %{ $datum->{transforms}->{whois}->{$key} }){
#						$datum->{$field} = $datum->{transforms}->{whois}->{$key}->{$field};
#				}
				last;
			}
		}
	}
	
	return $self;
}

sub _lookup {
	my $self = shift;
	my $datum = shift;
	my $field = shift;
	my $ip = shift;
	
	my $ret = $datum->{transforms}->{whois}->{$field};
	$self->log->trace('Looking up ip ' . $ip);
	$self->cv->begin;
		
	# Check known orgs
	my $ip_int = unpack('N*', inet_aton($ip));
	if ($self->conf->get('transforms/whois/known_subnets') and $self->conf->get('transforms/whois/known_orgs')){
		my $known_subnets = $self->conf->get('transforms/whois/known_subnets');
		my $known_orgs = $self->conf->get('transforms/whois/known_orgs');
		foreach my $start (keys %$known_subnets){
			my $start_int = unpack('N*', inet_aton($start));
			if ($start_int <= $ip_int and unpack('N*', inet_aton($known_subnets->{$start}->{end})) >= $ip_int){
				$datum->{customer} = $known_subnets->{$start}->{org};
				foreach my $key qw(name descr org cc country state city){
					$ret->{$key} = $known_orgs->{ $known_subnets->{$start}->{org} }->{$key};
				}
				$self->log->trace('using local org');
				$ret->{is_local} = 1;
				$self->cv->end;
				return;
			}
		}
	}
	my $ip_url = 'http://whois.arin.net/rest/ip/' . $ip;
	my $ip_info = $self->cache->get($ip_url);
	if ($ip_info){
		$self->log->trace( 'Using cached ip ' . Dumper($ip_info) );
		$ret->{name} = $ip_info->{name};
		$ret->{descr} = $ip_info->{descr};
		$ret->{org} = $ip_info->{org};
		$ret->{cc} = $ip_info->{cc} if exists $ret->{cc};
		my $org_url = $ip_info->{org_url};
		unless ($org_url){
			$self->log->warn('No org_url found from ip_url ' . $ip_url . ' in ip_info: ' . Dumper($ip_info));
			$self->cv->end;
			return;
		}
		
		my $org = $self->cache->get($org_url);
		if ($org){
			$self->log->trace( 'Using cached org' );
		}
		else {
			$org = $self->_lookup_org($datum, $org_url, $field);
		}
		
		$self->cv->end;
		return;
	}
	
	$self->log->debug( 'getting ' . $ip_url );
	http_request GET => $ip_url, headers => { Accept => 'application/json' }, sub {
		my ($body, $hdr) = @_;
		my $whois;
		eval {
			$whois = decode_json($body);
		};
		if ($@){
			$self->log->error('Error getting ' . $ip_url . ': ' . $@);
			$self->cv->end;
			return;
		}
		$self->log->trace( 'got whois: ' . Dumper($whois) );
		if ($whois->{net}->{orgRef}){
			if ($whois->{net}->{orgRef}->{'@name'}){
				my $org;
				if ($whois->{net}->{orgRef}->{'@handle'} eq 'RIPE'
					or $whois->{net}->{orgRef}->{'@handle'} eq 'APNIC'
					or $whois->{net}->{orgRef}->{'@handle'} eq 'AFRINIC'
					or $whois->{net}->{orgRef}->{'@handle'} eq 'LACNIC'){
					$self->log->trace('Getting RIPE IP with org ' . $whois->{net}->{orgRef}->{'@handle'});
					$org = $self->_lookup_ip_ripe($datum, $whois->{net}->{orgRef}->{'@handle'}, $ip, $field);
				}
				else {
					$ret->{name} = $whois->{net}->{name}->{'$'};
					$ret->{descr} = $whois->{net}->{orgRef}->{'@name'};
					$ret->{org} = $whois->{net}->{orgRef}->{'@handle'};
					
					my $org_url = $whois->{net}->{orgRef}->{'$'};
					$self->log->debug( 'set cache for ' . $ip_url );
					#TODO set the cache for the subnet, not the IP so we can avoid future lookups to the same subnet
					$self->cache->set($ip_url, {
						name => $ret->{name},
						descr => $ret->{descr},
						org => $ret->{org},
						org_url => $org_url,
					});
					
					$org = $self->cache->get($org_url);
					if ($org){
						$self->log->trace( 'Using cached org' );		
					}
					else {
						$self->_lookup_org($datum, $org_url, $field);
					}
				}
			}
		}
		$self->cv->end;
		return;
	}
}

sub _lookup_ip_ripe {
	my $self = shift;
	my $datum = shift;
	my $registrar = shift;
	my $ip = shift;
	my $field = shift;
	
	my $ret = $datum->{transforms}->{whois}->{$field};
	
	my $ripe_url = 'http://apps.db.ripe.net/whois/grs-lookup/' . lc($registrar) . '-grs/inetnum/' . $ip;
	my $cached = $self->cache->get($ripe_url);
	if ($cached){
		$self->log->trace('Using cached url ' . $ripe_url); 
		foreach my $key (keys %$cached){
			$ret->{$key} = $cached->{$key};
		}
		$self->log->trace('end');
		$self->cv->end;
		return;
	}
	
	$self->cv->begin;
	$self->log->trace('Getting ' . $ripe_url);
	http_request GET => $ripe_url, headers => { Accept => 'application/json' }, sub {
		my ($body, $hdr) = @_;
		my $whois;
		eval {
			$whois = decode_json($body);
		};
		if ($@){
			$self->log->error($body . ' ' . $ripe_url);
			$self->cv->end;
			return;
		}
		if ($whois->{'whois-resources'} 
			and $whois->{'whois-resources'}->{objects}
			and $whois->{'whois-resources'}->{objects}->{object}
			and $whois->{'whois-resources'}->{objects}->{object}->{attributes}
			and $whois->{'whois-resources'}->{objects}->{object}->{attributes}->{attribute}
			and $whois->{'whois-resources'}->{objects}->{object}->{attributes}->{attribute}){
			foreach my $attr (@{ $whois->{'whois-resources'}->{objects}->{object}->{attributes}->{attribute} }){
				if ($attr->{name} eq 'descr'){
					$ret->{descr} = $ret->{descr} ? $ret->{descr} . ' ' . $attr->{value} : $attr->{value};
					$ret->{name} = $ret->{descr};
				}
				elsif ($attr->{name} eq 'country'){
					$ret->{cc} = $attr->{value};
				}
				elsif ($attr->{name} eq 'netname'){
					$ret->{org} = $attr->{value};
				}
			}
			$self->log->trace( 'set cache for ' . $ripe_url );
			$self->cache->set($ripe_url, {
				cc => $ret->{cc},
				descr => $ret->{descr},
				name => $ret->{name},
				org => $ret->{org},
			});
		}
		else {
			$self->log->trace( 'RIPE: ' . Dumper($whois) );
		}
		$self->cv->end;
	};
	return;
}

sub _lookup_org {
	my $self = shift;
	my $datum = shift;
	my $org_url = shift;
	my $field = shift;
	
	$org_url =~ /\/([^\/]+)$/;
	my $key = $1;
	my $ret = $datum->{transforms}->{whois}->{$field};
	
	if (my $cached = $self->cache->get($key)){
		$self->log->trace('Using cached url ' . $org_url . ' with key ' . $key); 
		return $cached;
	}
	
	$self->cv->begin;
	$self->log->trace( 'getting ' . $org_url );
	http_request GET => $org_url, headers => { Accept => 'application/json' }, sub {
		my ($body, $hdr) = @_;
		my $whois = decode_json($body);
		if ($whois->{org}->{'iso3166-1'}){
			$ret->{cc} = $whois->{org}->{'iso3166-1'}->{code2}->{'$'};
			$ret->{country} = $whois->{org}->{'iso3166-1'}->{name}->{'$'};
		}
		if ($whois->{org}->{'iso3166-2'}){
			$ret->{state} = $whois->{org}->{'iso3166-2'}->{'$'};
		}
		if ($whois->{org}->{city}){
			$ret->{city} = $whois->{org}->{city}->{'$'};
		}
		$self->log->trace( 'set cache for ' . $org_url . ' with key ' . $key);
		my $data = { 
			cc => $ret->{cc},
			country => $ret->{country},
			state => $ret->{state},
			city => $ret->{city},
		};
		$self->cache->set($key, $data);
		
		$self->cv->end;
		return;
	};
}	
 
1;