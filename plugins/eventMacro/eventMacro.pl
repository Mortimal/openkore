package eventMacro;

use lib $Plugins::current_plugin_folder;

use strict;
use Getopt::Long qw( GetOptionsFromArray );
use Time::HiRes qw( &time );
use Plugins;
use Settings;
use Globals;
use Utils;
use Misc;
use Log qw(message error warning debug);
use Translation qw( T TF );
use AI;

use eventMacro::Core;
use eventMacro::Data;
use eventMacro::Lists;
use eventMacro::Automacro;
use eventMacro::FileParser;
use eventMacro::Macro;
use eventMacro::Runner;
use eventMacro::Utilities qw(find_variable);


Plugins::register('eventMacro', 'allows usage of eventMacros', \&Unload);

my $hooks = Plugins::addHooks(
	['configModify', \&onConfigModify, undef],
	['start3',       \&onstart3, undef],
	['pos_load_config.txt',       \&checkConfig, undef],
);

my $chooks = Commands::register(
	['eventMacro', "eventMacro plugin", \&commandHandler]
);

my $file_handle;
my $file;
my $parseAndHook_called;

sub Unload {
	message "[eventMacro] Plugin unloading\n", "system";
	Settings::removeFile($file_handle) if defined $file_handle;
	undef $file_handle;
	undef $file;
	if (defined $eventMacro) {
		$eventMacro->unload();
		undef $eventMacro;
	}
	Plugins::delHooks($hooks);
	Commands::unregister($chooks);
}

sub checkConfig {
	$timeout{eventMacro_delay}{timeout} = 1 unless defined $timeout{eventMacro_delay};
	$config{eventMacro_orphans} = 'terminate' unless defined $config{eventMacro_orphans};
	$config{eventMacro_CheckOnAI} = 'auto' unless defined $config{eventMacro_CheckOnAI};
	$file = (defined $config{eventMacro_file}) ? $config{eventMacro_file} : "eventMacros.txt";
	return 1;
}

sub onstart3 {
	debug "[eventMacro] Loading start\n", "eventMacro", 2;
	$file_handle = Settings::addControlFile($file,loader => [\&parseAndHook], mustExist => 0);
	$parseAndHook_called = 0;
	Settings::loadByHandle($file_handle);
	if (!$parseAndHook_called) {
		warning "[eventMacro] No control/eventMacros.txt file was found. Plugin disabled.\n";
		Commands::run('plugin unload eventMacro');
	}
}

sub onConfigModify {
	my (undef, $args) = @_;
	if ($args->{key} eq 'eventMacro_file') {
		Settings::removeFile($file_handle);
		$file_handle = Settings::addControlFile($args->{val}, loader => [ \&parseAndHook]);
		Settings::loadByHandle($file_handle);
	}
}

sub parseAndHook {
	my $file = shift;
	$parseAndHook_called++;
	debug "[eventMacro] Starting to parse file '$file'\n", "eventMacro", 2;
	if (defined $eventMacro) {
		debug "[eventMacro] Plugin global variable '\$eventMacro' is already defined, this must be a file reload. Unloading all current config.\n", "eventMacro", 2;
		$eventMacro->unload();
		undef $eventMacro;
		debug "[eventMacro] Plugin global variable '\$eventMacro' was set to undefined.\n", "eventMacro", 2;
	}
	$eventMacro = new eventMacro::Core($file);
	if ($eventMacro->{parse_failed}) {
		debug "[eventMacro] Loading error\n", "eventMacro", 2;
		return;
	} else {
		debug "[eventMacro] Loading success\n", "eventMacro", 2;
	}
	
	if ($char && $net && $net->getState() == Network::IN_GAME) {
		$eventMacro->check_all_conditions();
	}
}

sub commandHandler {
	### no parameter given
	if (!defined $_[1]) {
		message "usage: eventMacro [MACRO|auto|list|status|check|stop|pause|unpause|var_get|var_set|enable|disable|include] [extras]\n", "list";
		message 
			"eventMacro MACRO: Run macro MACRO\n".
			"eventMacro auto AUTOMACRO: Get info on an automacro and it's conditions\n".
			"eventMacro list: Lists available macros and automacros\n".
			"eventMacro status [macro|automacro]: Shows current status of automacro, macro or both\n".
			"eventMacro check [force_stop|force_start|resume] [slot]: Sets the state of automacros checking\n".
			"eventMacro stop [slot]: Stops current running macro\n".
			"eventMacro pause [slot]: Pauses current running macro\n".
			"eventMacro unpause [slot]: Unpauses current running macro\n".
			"eventMacro var_get: Shows the value of one or all variables\n".
			"eventMacro var_set: Set the value of a variable\n".
			"eventMacro enable [automacro]: Enable one or all automacros\n".
			"eventMacro disable [automacro]: Disable one or all automacros\n".
			"eventMacro include [on|off|list] <filename or pattern>: Enables or disables !include in eventMacros file\n";
		return;
	}
	my ( $arg, @params ) = parseArgs( $_[1] );
	
	if ($arg eq 'auto') {
		my $automacro = $eventMacro->{Automacro_List}->getByName($params[0]);
		if (!$automacro) {
			error "[eventMacro] Automacro '".$params[0]."' not found.\n"
		} else {
			my $message = "[eventMacro] Printing information about automacro '".$automacro->get_name."'.\n";
			my $condition_list = $automacro->{conditionList};
			my $size = $condition_list->size;
			my $is_event = $automacro->has_event_type_condition;
			$message .= "Number of conditions: '".$size."'\n";
			$message .= "Has event type condition: '". ($is_event ? 'yes' : 'no') ."'\n";
			$message .= "Number of true conditions: '".($size - $automacro->{number_of_false_conditions} - $is_event)."'\n";
			$message .= "Number of false conditions: '".$automacro->{number_of_false_conditions}."'\n";
			$message .= "Is triggered: '".$automacro->running_status."'\n";
			
			$message .= "----  Parameters   ----\n";
			my $counter = 1;
			foreach my $parameter (keys %{$automacro->{parameters}}) {
				$message .= $counter." - ".$parameter.": '".$automacro->{parameters}->{$parameter}."'\n";
			} continue {
				$counter++;
			}
			
			$message .= "----  Conditions   ----\n";
			$counter = 1;
			foreach my $condition (@{$condition_list->getItems}) {
				if ($condition->condition_type == EVENT_TYPE) {
					$message .= $counter." - ".$condition->get_name.": event type condition\n";
				} else {
					$message .= $counter." - ".$condition->get_name.": '". ($condition->is_fulfilled ? 'true' : 'false') ."'\n";
				}
			} continue {
				$counter++;
			}
			
			
			my $check_state = $eventMacro->{automacros_index_to_AI_check_state}{$automacro->get_index};
			$message .= "----  AI check states   ----\n";
			$message .= "Check on AI off: '". ($check_state->{AI::OFF} ? 'yes' : 'no') ."'\n";
			$message .= "Check on AI manual: '". ($check_state->{AI::MANUAL} ? 'yes' : 'no') ."'\n";
			$message .= "Check on AI auto: '". ($check_state->{AI::AUTO} ? 'yes' : 'no') ."'\n";
			
			$message .= "----  End   ----\n";
			
			message $message;
		}
	
	
	### parameter: list
	} elsif ($arg eq 'list') {
		message( "The following macros are available:\n" );

		message( center( T( ' Macros ' ), 25, '-' ) . "\n", 'list' );
		message( $_->get_name . "\n" ) foreach sort { $a->get_name cmp $b->get_name } @{ $eventMacro->{Macro_List}->getItems };

		message( center( T( ' Auto Macros ' ), 25, '-' ) . "\n", 'list' );
		message( $_->get_name . "\n" ) foreach sort { $a->get_name cmp $b->get_name } @{ $eventMacro->{Automacro_List}->getItems };

		message( center( T( ' Perl Subs ' ), 25, '-' ) . "\n", 'list' );
		message( "$_\n" ) foreach sort @perl_name;

		message( center( '', 25, '-' ) . "\n", 'list' );
		
		
	### parameter: status
	} elsif ($arg eq 'status') {
		if (defined $params[0] && $params[0] ne 'macro' && $params[0] ne 'automacro') {
			message "[eventMacro] '".$params[0]."' is not a valid option\n";
			return;
		}
		
		my $show_automacro = (!defined $params[0] || $params[0] eq 'automacro') ? 1 : 0;
		my $show_macro = (!defined $params[0] || $params[0] eq 'macro') ? 1 : 0;
		
		foreach my $slot (sort keys %{$eventMacro->{Automacro_Checking_slots}}) {
			message( center( " Slot ".$slot." ", 30, '-' ) . "\n", 'list' );
			
			if ($show_automacro) {
				message( center( " Automacro ", 20, '-' ) . "\n", 'list' );
				my $status = $eventMacro->get_automacro_checking_status($slot);
				if ($status == CHECKING_AUTOMACROS) {
					message "- Automacros are being checked normally.\n";
				} elsif ($status == PAUSED_BY_EXCLUSIVE_MACRO) {
					message "- Automacros are not being checked because there's an uninterruptible macro running ('".$eventMacro->{Macro_Runner}{$slot}->last_subcall_name."').\n";
				} elsif ($status == PAUSE_FORCED_BY_USER) {
					message "- Automacros checking is stopped because the user forced it.\n";
				} else {
					message "- Automacros checking is active because the user forced it.\n";
				}
				message "\n";
			}
			
			if ($show_macro) {
				message( center( " Macro ", 20, '-' ) . "\n", 'list' );
				if (!exists $eventMacro->{Macro_Runner}{$slot}) {
					message( "- There's no macro currently running.\n", "list" );
					
				} else {
					my $macro = $eventMacro->{Macro_Runner}{$slot};
					
					my $macro_tree_message = "- Macro tree: '".$macro->get_name."'";
					my $submacro = $macro;
					while (defined $submacro->{subcall}) {
						$submacro = $submacro->{subcall};
						$macro_tree_message .= " --> '".$submacro->get_name."'";
					}
					$macro_tree_message .= ".\n";
					message( $macro_tree_message, "list" );
					
					while () {
						message( sprintf( "- Macro name: %s\n", $macro->get_name ), "list" );
						message( sprintf( "- Paused: %s\n", $macro->is_paused ? "yes" : "no" ) );
						message( sprintf( "- overrideAI: %s\n", $macro->overrideAI ), "list" );
						message( sprintf( "- interruptible: %s\n", $macro->interruptible ), "list" );
						message( sprintf( "- orphan method: %s\n", $macro->orphan ), "list" );
						message( sprintf( "- remaining repeats: %s\n", $macro->repeat ), "list" );
						message( sprintf( "- slot: %s\n", $macro->slot ), "list" );
						message( sprintf( "- macro delay: %s\n", $macro->macro_delay ), "list" );
						
						message( sprintf( "- current command: %s\n", $macro->{current_line} ), "list" );
						
						my $time_until_next_command = (($macro->timeout->{time} + $macro->timeout->{timeout}) - time);
						message( sprintf( "- time until next command: %s\n", $time_until_next_command ), "list" ) if ($time_until_next_command > 0);
						
						message "\n";
						
						last if (!defined $macro->{subcall});
						$macro = $macro->{subcall};
					}
				}
				message "\n";
			}
		}
		
	### parameter: check
	} elsif ($arg eq 'check') {
		if (!defined $params[0] || (defined $params[0] && $params[0] ne 'force_stop' && $params[0] ne 'force_start' && $params[0] ne 'resume')) {
			message "usage: eventMacro check [force_stop|force_start|resume] [slot]\n", "list";
			message
				"eventMacro check force_stop [slot]: forces the stop of automacros checking [in a certain slot].\n".
				"eventMacro check force_start [slot]: forces the start of automacros checking [in a certain slot].\n".
				"eventMacro check resume [slot]: return automacros checking to the normal state [in a certain slot].\n";
			return;
		}
		
		my $new_status = $params[0];
		
		if (defined $params[1]) {
			my $slot = $params[1];
			
			if ($slot !~ /^\d+$/) {
				message "[eventMacro] '".$slot."' is not a valid option\n";
				return;
			}
			if (!exists $eventMacro->{Automacros_Checking_Status}{$slot}) {
				message "[eventMacro] Slot '".$slot."' does not exist\n";
				return;
			}
			
			debug "[eventMacro] Command 'check' used with parameter '".$new_status."' and slot ".$slot.".\n", "eventMacro", 2;
		   
			check_command_enforce($new_status, $slot);
			
		} else {
			debug "[eventMacro] Command 'check' used with parameter '".$new_status."' and no slot defined.\n", "eventMacro", 2;
			foreach my $slot (sort keys %{$eventMacro->{Automacro_Checking_slots}}) {
				check_command_enforce($new_status, $slot);
			}
		}
   
   
    ### parameter: stop
	} elsif ($arg eq 'stop') {
	
		if (defined $params[0]) {
			if ($params[0]  !~ /\d+/) {
				message "[eventMacro] '".$params[0]."' is not a valid option\n";
				return;
			}
			
			my $slot = $params[0];
			
			if (!exists $eventMacro->{Automacro_Checking_slots}{$slot}) {
				message "[eventMacro] Slot '".$params[0]."' does not exist.\n";
				return;
			}
			
			if (!exists $eventMacro->{Macro_Runner}{$slot}) {
				message "[eventMacro] There's no macro currently running in slot '".$params[0]."'.\n";
				return;
			}
			
			my $macro = $eventMacro->{Macro_Runner}{$slot};
			message "[eventMacro] Stopping macro '".$macro->last_subcall_name."'.\n";
			$eventMacro->clear_queue($slot);
			
		} else {
			foreach my $slot (keys %{$eventMacro->{Macro_Runner}}) {
				my $macro = $eventMacro->{Macro_Runner}{$slot};
				message "[eventMacro] Stopping macro '".$macro->last_subcall_name."'.\n";
				$eventMacro->clear_queue($slot);
			}
		}
		
		
	### parameter: pause
	} elsif ($arg eq 'pause') {
	
		if (defined $params[0]) {
			if ($params[0]  !~ /\d+/) {
				message "[eventMacro] '".$params[0]."' is not a valid option\n";
				return;
			}
			
			my $slot = $params[0];
			
			if (!exists $eventMacro->{Automacro_Checking_slots}{$slot}) {
				message "[eventMacro] Slot '".$params[0]."' does not exist.\n";
				return;
			}
			
			if (!exists $eventMacro->{Macro_Runner}{$slot}) {
				message "[eventMacro] There's no macro currently running in slot '".$params[0]."'.\n";
				return;
			}
			
			my $macro = $eventMacro->{Macro_Runner}{$slot};
			
			if ($macro->is_paused()) {
				message "[eventMacro] Macro '".$macro->last_subcall_name."' is already paused.\n";
				return;
			}
			
			message "[eventMacro] Pausing macro '".$macro->last_subcall_name."'.\n";
			$macro->pause();
			
		} else {
			foreach my $slot (keys %{$eventMacro->{Macro_Runner}}) {
				my $macro = $eventMacro->{Macro_Runner}{$slot};
				next if ($macro->is_paused());
				message "[eventMacro] Pausing macro '".$macro->last_subcall_name."'.\n";
				$macro->pause();
			}
		}
		
		
	### parameter: unpause
	} elsif ($arg eq 'unpause') {
	
		if (defined $params[0]) {
			if ($params[0]  !~ /\d+/) {
				message "[eventMacro] '".$params[0]."' is not a valid option\n";
				return;
			}
			
			my $slot = $params[0];
			
			if (!exists $eventMacro->{Automacro_Checking_slots}{$slot}) {
				message "[eventMacro] Slot '".$params[0]."' does not exist.\n";
				return;
			}
			
			if (!exists $eventMacro->{Macro_Runner}{$slot}) {
				message "[eventMacro] There's no macro currently running in slot '".$params[0]."'.\n";
				return;
			}
			
			my $macro = $eventMacro->{Macro_Runner}{$slot};
			
			unless ($macro->is_paused()) {
				message "[eventMacro] Macro '".$macro->last_subcall_name."' is not paused.\n";
				return;
			}
			
			message "[eventMacro] Unpausing macro '".$macro->last_subcall_name."'.\n";
			$macro->unpause();
			
		} else {
			foreach my $slot (keys %{$eventMacro->{Macro_Runner}}) {
				my $macro = $eventMacro->{Macro_Runner}{$slot};
				next unless ($macro->is_paused());
				message "[eventMacro] Unpausing macro '".$macro->last_subcall_name."'.\n";
				$macro->unpause();
			}
		}
		
	### parameter: var_get
	} elsif ($arg eq 'var_get') {
		if (!defined $params[0]) {
			my $counter;
			message "[eventMacro] Printing values off all variables\n", "menu";
			
			$counter = 1;
			message( center( " Scalars ", 25, '-' ) . "\n", 'list' );
			foreach my $scalar_name (keys %{$eventMacro->{Scalar_Variable_List_Hash}}) {
				my $value = $eventMacro->{Scalar_Variable_List_Hash}{$scalar_name};
				$value = 'undef' unless (defined $value);
				message $counter." - '\$".$scalar_name."' = '".$value."'\n", "menu";
			} continue {
				$counter++;
			}
			
			$counter = 1;
			message( center( " Arrays ", 25, '-' ) . "\n", 'list' );
			foreach my $array_name (keys %{$eventMacro->{Array_Variable_List_Hash}}) {
				message $counter." - '@".$array_name."'\n", "menu";
				foreach my $index (0..$#{$eventMacro->{Array_Variable_List_Hash}{$array_name}}) {
					my $value = $eventMacro->{Array_Variable_List_Hash}{$array_name}[$index];
					$value = 'undef' unless (defined $value);
					message "     '\$".$array_name."[".$index."]' = '".$value."'\n", "menu";
				}
			} continue {
				$counter++;
			}
			
			$counter = 1;
			message( center( " Hashes ", 25, '-' ) . "\n", 'list' );
			foreach my $hash_name (keys %{$eventMacro->{Hash_Variable_List_Hash}}) {
				message $counter." - '%".$hash_name."'\n", "menu";
				my $hash = $eventMacro->{Hash_Variable_List_Hash}{$hash_name};
				foreach my $key (keys %{$hash}) {
					my $value = $eventMacro->{Hash_Variable_List_Hash}{$hash_name}{$key};
					$value = 'undef' unless (defined $value);
					message "     '\$".$hash_name."{".$key."}' = '".$value."'\n", "menu";
				}
			} continue {
				$counter++;
			}
		
		} else {
			if (my $var = find_variable($params[0])) {
				if ($var->{type} eq 'scalar') {
					if (exists $eventMacro->{Scalar_Variable_List_Hash}{$var->{real_name}}) {
						my $var_value = $eventMacro->get_scalar_var($var->{real_name});
						$var_value = 'undef' unless (defined $var_value);
						message "'[eventMacro] '".$var->{display_name}."' = '".$var_value."'\n", "menu";
						
					} else {
						message "[eventMacro] Scalar variable '".$var->{display_name}."' doesn't exist\n";
					}
					
				} elsif ($var->{type} eq 'accessed_array') {
					if (exists $eventMacro->{Array_Variable_List_Hash}{$var->{real_name}}) {
						my $var_value = $eventMacro->get_array_var($var->{real_name}, $var->{complement});
						$var_value = 'undef' unless (defined $var_value);
						message "'[eventMacro] '".$var->{display_name}."' = '".$var_value."'\n", "menu";
						
					} else {
						message "[eventMacro] Array variable '".$var->{display_name}."' doesn't exist\n";
					}
					
				} elsif ($var->{type} eq 'array') {
					if (exists $eventMacro->{Array_Variable_List_Hash}{$var->{real_name}}) {
						message "[eventMacro] '".$var->{display_name}."'\n";
						
						foreach my $index (0..$#{$eventMacro->{Array_Variable_List_Hash}{$var->{real_name}}}) {
							my $value = $eventMacro->{Array_Variable_List_Hash}{$var->{real_name}}[$index];
							$value = 'undef' unless (defined $value);
							message "[eventMacro] '\$".$var->{real_name}."[".$index."]' = '".$value."'\n", "menu";
						}
						
					} else {
						message "[eventMacro] Array variable '".$var->{display_name}."' doesn't exist\n";
					}
					
				} elsif ($var->{type} eq 'accessed_hash') {
					if (exists $eventMacro->{Hash_Variable_List_Hash}{$var->{real_name}}) {
						my $var_value = $eventMacro->get_hash_var($var->{real_name}, $var->{complement});
						$var_value = 'undef' unless (defined $var_value);
						message "'[eventMacro] '".$var->{display_name}."' = '".$var_value."'\n", "menu";
						
					} else {
						message "[eventMacro] Hash variable '".$var->{display_name}."' doesn't exist\n";
					}
					
				} elsif ($var->{type} eq 'hash') {
					if (exists $eventMacro->{Hash_Variable_List_Hash}{$var->{real_name}}) {
						message "[eventMacro] '".$var->{display_name}."'\n";
						my $hash = $eventMacro->{Hash_Variable_List_Hash}{$var->{real_name}};
						foreach my $key (keys %{$hash}) {
							my $value = $eventMacro->{Hash_Variable_List_Hash}{$var->{real_name}}{$key};
							$value = 'undef' unless (defined $value);
							message "[eventMacro] '\$".$var->{real_name}."{".$key."}' = '".$value."'\n", "menu";
						}
						
					} else {
						message "[eventMacro] Hash variable '".$var->{display_name}."' doesn't exist\n";
					}
				}
				
			} else {
				message "[eventMacro] '".$params[0]."' is not a valid variable name syntax\n";
			}
		}
	
	### parameter: var_set
	} elsif ($arg eq 'var_set') {
		if (!defined $params[0] || !defined $params[1]) {
			message "usage: eventMacro var_set [variable name] [variable value]\n", "list";
			
		} else {
			if (my $var = find_variable($params[0])) {
				if ($var->{real_name} =~ /^\./) {
					error "[eventMacro] System variables cannot be set by hand (The ones starting with a dot '.')\n";
					
				} elsif ($var->{type} eq 'scalar') {
					message "[eventMacro] Setting the value of scalar variable '".$var->{display_name}."' to '".$params[1]."'.\n";
					$eventMacro->set_scalar_var($var->{real_name}, $params[1]);
					
				} elsif ($var->{type} eq 'accessed_array') {
					message "[eventMacro] Setting the value of array variable '".$var->{display_name}."' to '".$params[1]."'.\n";
					$eventMacro->set_array_var($var->{real_name}, $var->{complement}, $params[1]);
					
				} elsif ($var->{type} eq 'array') {
					my $value = join('', @params[1..$#params]);
					if ($value =~ /^\((.*)\)$/i) {
						message "[eventMacro] Setting the value of array variable '".$var->{display_name}."' to '".$value."'.\n";
						my @members = split(/\s*,\s*/, $1);
						$eventMacro->set_full_array($var->{real_name}, \@members);
						
					} else {
						message "[eventMacro] '".$params[1]."' is not a valid array value syntax. Correct syntax:\n".
						        "\@array_name (member1,member2,member3).\n";
					}
					
				} elsif ($var->{type} eq 'accessed_hash') {
					message "[eventMacro] Setting the value of hash variable '".$var->{display_name}."' to '".$params[1]."'.\n";
					$eventMacro->set_hash_var($var->{real_name}, $var->{complement}, $params[1]);
					
				} elsif ($var->{type} eq 'hash') {
					my $value = join('', @params[1..$#params]);
					if ($value =~ /^\((.*)\)$/i) {
						message "[eventMacro] Setting the value of hash variable '".$var->{display_name}."' to '".$value."'.\n";
						my @members = split(/\s*,\s*/, $1);
						my %hash;
						foreach my $hash_member (@members) {
							my ($key, $value) = split(/\s*=>\s*/, $hash_member);
							if ($hash_member =~ /(.+)\s*=>\s*(.+)/) {
								my $key = $1;
								my $value = $2;
								$hash{$key} = $value;
							} else {
								message "[eventMacro] '".$params[1]."' is not a valid hash key/value pair syntax. Correct syntax:\n".
									"key1 => value1\n";
								return;
							}
						}
						$eventMacro->set_full_hash($var->{real_name}, \%hash);
						
					} else {
						message "[eventMacro] '".$params[1]."' is not a valid hash value syntax. Correct syntax:\n".
						        "\%hash_name (key1 => value1, key2 => value2).\n";
					}
				}
			} else {
				message "[eventMacro] '".$params[0]."' is not a valid variable name syntax\n";
			}
		}
		
		
	### parameter: enable
	} elsif ($arg eq 'enable') {
		if (!defined $params[0] || $params[0] eq 'all') {
			$eventMacro->enable_all_automacros();
			message "[eventMacro] All automacros were enabled.\n";
			return;
		}
		for my $automacro_name (@params) {
			my $automacro = $eventMacro->{Automacro_List}->getByName($automacro_name);
			if (!$automacro) {
				error "[eventMacro] Automacro '".$automacro_name."' not found.\n"
			} else {
				message "[eventMacro] Enabled automacro '".$automacro_name."'.\n";
				$eventMacro->enable_automacro($automacro);
			}
		}
		

	### parameter: disable
	} elsif ($arg eq 'disable') {
		if (!defined $params[0] || $params[0] eq 'all') {
			$eventMacro->disable_all_automacros();
			message "[eventMacro] All automacros were disabled.\n";
			return;
		}
		for my $automacro_name (@params) {
			my $automacro = $eventMacro->{Automacro_List}->getByName($automacro_name);
			if (!$automacro) {
				error "[eventMacro] Automacro '".$automacro_name."' not found.\n"
			} else {
				message "[eventMacro] Disabled automacro '".$automacro_name."'.\n";
				$eventMacro->disable_automacro($automacro);
			}
		}
		
	### parameter: include
	} elsif ($arg eq 'include') {
	
		if (
		($params[0] ne 'list' && $params[0] ne 'on' && $params[0] ne 'off') ||
		($params[0] eq 'list' && @params > 1) ||
		(($params[0] eq 'on' || $params[0] eq 'off') && @params < 2) ||
		(@params > 2 || @params < 1)
		) {
			message "[eventMacro] Usage:\n".
					"eventMacro include on <filename or pattern>\n".
					"eventMacro include on all\n".
					"eventMacro include off <filename or pattern>\n".
					"eventMacro include off all\n".
					"eventMacro include list\n", 'list';
			return;
		}
		$eventMacro->include($params[0], $params[1]);
	
	### if nothing triggered until here it's probably a macro name
	} elsif ( !$eventMacro->{Macro_List}->getByName( $arg ) ) {
		error "[eventMacro] Macro $arg not found\n";
		
	} else {
		my $opt = {};
		GetOptionsFromArray( \@params, $opt, 'repeat|r=i', 'slot=i', 'overrideAI', 'exclusive', 'macro_delay=f', 'orphan=s' );
		
		my $slot = defined $opt->{slot} ? $opt->{slot} : 1;
		
		if ( exists $eventMacro->{Macro_Runner}{$slot} ) {
			warning "[eventMacro] A macro is already running in slot ".$slot.". Wait until the macro has finished or call 'eventMacro stop [".$slot."]'\n";
			return;
		}
		
		$eventMacro->set_full_array( ".param", \@params );
		
		$eventMacro->{Macro_Runner}{$slot} = new eventMacro::Runner(
			$arg,
			defined $opt->{repeat} ? $opt->{repeat} : 1,
			$slot,
			defined $opt->{exclusive} ? $opt->{exclusive} ? 0 : 1 : undef,
			defined $opt->{overrideAI} ? $opt->{overrideAI} : undef,
			defined $opt->{orphan} ? $opt->{orphan} : undef,
			undef,
			defined $opt->{macro_delay} ? $opt->{macro_delay} : undef,
			0
		);
	
		if (!defined $eventMacro->{Macro_Runner}{$slot}) {
			error "[eventMacro] unable to create macro queue.\n";
			delete $eventMacro->{Macro_Runner}{$slot};
			return;
		}
		
		if (keys %{$eventMacro->{Macro_Runner}} == 1) {
			my $iterate_macro_sub = sub { $eventMacro->iterate_macro(); };
			$eventMacro->{AI_start_Macros_Running_Hook_Handle} = Plugins::addHook( 'AI_start', $iterate_macro_sub, undef );
		}
	}
}

sub check_command_enforce {
	my ($new_status, $slot) = @_;
	my $old_status = $eventMacro->get_automacro_checking_status($slot);
	debug "[eventMacro] Previous slot ".$slot." checking status '".$old_status."'.\n", "eventMacro", 2;
	
	if ($new_status eq 'force_stop') {
		if ($old_status == CHECKING_AUTOMACROS) {
			message "[eventMacro] Slot ".$slot.": Automacros checking forcely stopped.\n";
			$eventMacro->set_automacro_checking_status($slot, PAUSE_FORCED_BY_USER);
		} elsif ($old_status == PAUSED_BY_EXCLUSIVE_MACRO) {
			message "[eventMacro] Slot ".$slot.": Automacros were not being checked because there's an uninterruptible macro running ('".$eventMacro->{Macro_Runner}{$slot}->last_subcall_name."').\n".
					"Now they will be forcely stopped even after macro ends (caution).\n";
			$eventMacro->set_automacro_checking_status($slot, PAUSE_FORCED_BY_USER);
		} elsif ($old_status == PAUSE_FORCED_BY_USER) {
			message "[eventMacro] Slot ".$slot.": Automacros checking is already forcely stopped.\n";
		} else {
			message "[eventMacro] Slot ".$slot.": Automacros checking is forcely active, now it will be forcely stopped.\n";
			$eventMacro->set_automacro_checking_status($slot, PAUSE_FORCED_BY_USER);
		}
			
	} elsif ($new_status eq 'force_start') {
		if ($old_status == CHECKING_AUTOMACROS) {
			message "[eventMacro] Slot ".$slot.": Automacros are already being checked, now it will be forcely kept this way.\n";
			$eventMacro->set_automacro_checking_status($slot, CHECKING_FORCED_BY_USER);
		} elsif ($old_status == PAUSED_BY_EXCLUSIVE_MACRO) {
			message "[eventMacro] Slot ".$slot.": Automacros were not being checked because there's an uninterruptible macro running ('".$eventMacro->{Macro_Runner}{$slot}->last_subcall_name."').\n".
					"Now automacros checking will be forcely activated (caution).\n";
			$eventMacro->set_automacro_checking_status($slot, CHECKING_FORCED_BY_USER);
		} elsif ($old_status == PAUSE_FORCED_BY_USER) {
			message "[eventMacro] Slot ".$slot.": Automacros checking is forcely stopped, now it will be forcely activated.\n";
			$eventMacro->set_automacro_checking_status($slot, CHECKING_FORCED_BY_USER);
		} else {
			message "[eventMacro] Slot ".$slot.": Automacros checking is already forcely active.\n";
		}
			
	} elsif ($new_status eq 'resume') {
		if ($old_status == CHECKING_AUTOMACROS || $old_status == PAUSED_BY_EXCLUSIVE_MACRO) {
			message "[eventMacro] Slot ".$slot.": Automacros checking is not forced by the user to be able to resume.\n";
		} else {
			if (!exists $eventMacro->{Macro_Runner}{$slot}) {
				message "[eventMacro] Slot ".$slot.": Since there's no macro in execution automacros will resume to being normally checked.\n";
				$eventMacro->set_automacro_checking_status($slot, CHECKING_AUTOMACROS);
			} elsif ($eventMacro->{Macro_Runner}{$slot}->last_subcall_interruptible == 1) {
				message "[eventMacro] Slot ".$slot.": Since there's a macro in execution, and it is interruptible, automacros will resume to being normally checked.\n";
				$eventMacro->set_automacro_checking_status($slot, CHECKING_AUTOMACROS);
			} elsif ($eventMacro->{Macro_Runner}{$slot}->last_subcall_interruptible == 0) {
				message "[eventMacro] Slot ".$slot.": Since there's a macro in execution ('".$eventMacro->{Macro_Runner}{$slot}->last_subcall_name."'), and it is not interruptible, automacros won't resume to being checked until it ends.\n";
				$eventMacro->set_automacro_checking_status($slot, PAUSED_BY_EXCLUSIVE_MACRO);
			}
		}
	}
}

1;