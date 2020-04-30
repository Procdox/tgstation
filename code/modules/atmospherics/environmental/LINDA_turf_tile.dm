#define MINIMUM_HEAT_CAPACITY	0.0003
#define MINIMUM_MOLE_COUNT		0.01
#define MOLAR_ACCURACY  1E-7
#define QUANTIZE(variable) (round((variable), (MOLAR_ACCURACY)))

/turf
	//used for temperature calculations
	var/thermal_conductivity = 0.05
	var/heat_capacity = 1
	var/temperature_archived

	//list of open turfs adjacent to us
	var/list/atmos_adjacent_turfs
	//bitfield of dirs in which we are superconducitng
	var/atmos_supeconductivity = NONE

	//used to determine whether we should archive
	var/archived_cycle = 0
	var/current_cycle = 0

	//used for mapping and for breathing while in walls (because that's a thing that needs to be accounted for...)
	//string parsed by /datum/gas/proc/copy_from_turf
	var/initial_gas_mix = OPENTURF_DEFAULT_ATMOS
	//approximation of MOLES_O2STANDARD and MOLES_N2STANDARD pending byond allowing constant expressions to be embedded in constant strings
	// If someone will place 0 of some gas there, SHIT WILL BREAK. Do not do that.

/turf/open
	//used for spacewind
	var/pressure_difference = 0
	var/pressure_direction = 0

	var/datum/excited_group/excited_group
	var/atmo_state = ATMO_STATE_INACTIVE
	var/datum/gas_mixture/turf/air

	var/obj/effect/hotspot/active_hotspot
	var/shared_this_tick = 0
	var/stability_counter = 0
	var/rest_counter = 0
	var/planetary_atmos = FALSE //air will revert to initial_gas_mix over time

	var/list/atmos_overlay_types //gas IDs of current active gas overlays

/turf/open/Initialize()
	if(!blocks_air)
		air = new
		air.copy_from_turf(src)
	. = ..()

/turf/open/Destroy()
	if(active_hotspot)
		QDEL_NULL(active_hotspot)
	// Adds the adjacent turfs to the current atmos processing
	for(var/T in atmos_adjacent_turfs)
		SSair.add_to_active(T)
	return ..()

/////////////////GAS MIXTURE PROCS///////////////////

/turf/open/assume_air(datum/gas_mixture/giver) //use this for machines to adjust air
	if(!giver)
		return FALSE
	air.merge(giver)
	update_visuals()
	return TRUE

/turf/open/remove_air(amount)
	var/datum/gas_mixture/ours = return_air()
	var/datum/gas_mixture/removed = ours.remove(amount)
	update_visuals()
	return removed

/turf/open/proc/copy_air_with_tile(turf/open/T)
	if(istype(T))
		air.copy_from(T.air)

/turf/open/proc/copy_air(datum/gas_mixture/copy)
	if(copy)
		air.copy_from(copy)

/turf/return_air()
	RETURN_TYPE(/datum/gas_mixture)
	var/datum/gas_mixture/GM = new
	GM.copy_from_turf(src)
	return GM

/turf/open/return_air()
	RETURN_TYPE(/datum/gas_mixture)
	return air

/turf/open/return_analyzable_air()
	return return_air()

/turf/temperature_expose()
	if(temperature > heat_capacity)
		to_be_destroyed = TRUE

/turf/proc/archive()
	temperature_archived = temperature

/turf/open/archive()
	air.archive()
	archived_cycle = SSair.times_fired
	temperature_archived = temperature

/////////////////////////GAS OVERLAYS//////////////////////////////


/turf/open/proc/update_visuals()

	var/list/atmos_overlay_types = src.atmos_overlay_types // Cache for free performance
	var/list/new_overlay_types = list()
	var/static/list/nonoverlaying_gases = typecache_of_gases_with_no_overlays()

	if(!air) // 2019-05-14: was not able to get this path to fire in testing. Consider removing/looking at callers -Naksu
		if (atmos_overlay_types)
			for(var/overlay in atmos_overlay_types)
				vis_contents -= overlay
			src.atmos_overlay_types = null
		return

	var/list/gases = air.gases

	for(var/id in gases)
		if (nonoverlaying_gases[id])
			continue
		var/gas = gases[id]
		var/gas_meta = gas[GAS_META]
		var/gas_overlay = gas_meta[META_GAS_OVERLAY]
		if(gas_overlay && gas[MOLES] > gas_meta[META_GAS_MOLES_VISIBLE])
			new_overlay_types += gas_overlay[min(FACTOR_GAS_VISIBLE_MAX, CEILING(gas[MOLES] / MOLES_GAS_VISIBLE_STEP, 1))]

	if (atmos_overlay_types)
		for(var/overlay in atmos_overlay_types-new_overlay_types) //doesn't remove overlays that would only be added
			vis_contents -= overlay

	if (length(new_overlay_types))
		if (atmos_overlay_types)
			vis_contents += new_overlay_types - atmos_overlay_types //don't add overlays that already exist
		else
			vis_contents += new_overlay_types

	UNSETEMPTY(new_overlay_types)
	src.atmos_overlay_types = new_overlay_types

/proc/typecache_of_gases_with_no_overlays()
	. = list()
	for (var/gastype in subtypesof(/datum/gas))
		var/datum/gas/gasvar = gastype
		if (!initial(gasvar.gas_overlay))
			.[gastype] = TRUE

/////////////////////////////SIMULATION///////////////////////////////////

/turf/proc/process_cell(fire_count)
	SSair.remove_from_active(src)

/turf/open/process_cell(fire_count)
	ASSERT(atmo_state == ATMO_STATE_ACTIVE)

	if(fire_count > archived_cycle) //archive self if not already done
		archive()
	current_cycle = fire_count

	var/list/adjacent_turfs = atmos_adjacent_turfs
	var/datum/excited_group/local_group = excited_group
	
	var/local_k = LAZYLEN(adjacent_turfs) + 1
	var/planet_atmos = planetary_atmos
	if (planet_atmos)
		local_k++

	var/datum/gas_mixture/local_air = air
	var/list/local_mix = local_air.gases

	var/old_self_heat_capacity = local_air.heat_capacity()

	//for(var/id in total_delta)
	//	total_delta[id][ARCHIVE] = total_delta[id][MOLES]
	//	total_delta[id][MOLES] = 0

	//var/list/total_delta = new
	
	for(var/t in adjacent_turfs)
		var/turf/open/enemy_tile = t

		var/list/pair_delta = adjacent_turfs[t]
		var/datum/gas_mixture/enemy_air = enemy_tile.air

		//@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		//  sharing adjacent

		//short form for second-ordered pair element
		if(fire_count <= enemy_tile.current_cycle)

			var/heat_capacity_self_to_sharer = 0
			var/heat_capacity_sharer_to_self = 0

			for(var/id in pair_delta)
				//if(!total_delta[id]) total_delta[id] = 0

				var/local_gas = local_mix[id]
				var/delta = pair_delta[id][MOLES]

				ASSERT(delta)

				var/gas_heat_capacity = delta * local_gas[GAS_META][META_GAS_SPECIFIC_HEAT]
				if(delta < 0)
					heat_capacity_self_to_sharer -= gas_heat_capacity
				else
					heat_capacity_sharer_to_self += gas_heat_capacity

				local_gas[MOLES] += delta
				//total_delta[id] += delta

			var/new_self_heat_capacity = old_self_heat_capacity + heat_capacity_sharer_to_self - heat_capacity_self_to_sharer
			temperature = (old_self_heat_capacity*temperature - heat_capacity_self_to_sharer*temperature_archived + heat_capacity_sharer_to_self*enemy_air.temperature_archived)/new_self_heat_capacity

			old_self_heat_capacity = new_self_heat_capacity

			//skip grouping for second-ordered pair
			continue

		//long form for first-ordered pair element

		var/list/enemy_mix = enemy_air.gases
		var/enemy_k = enemy_tile.atmos_adjacent_turfs.len + (enemy_tile.planetary_atmos ? 2 : 1)
		var/k = (enemy_k > local_k ? enemy_k : local_k)

		if(fire_count > enemy_tile.archived_cycle)
			enemy_tile.archive()

		var/old_sharer_heat_capacity = enemy_air.heat_capacity()
		var/heat_capacity_self_to_sharer = 0
		var/heat_capacity_sharer_to_self = 0
		
		var/share = 0

		for(var/id in pair_delta)
			pair_delta[id][MOLES] = 0

		for(var/id in (enemy_mix || local_mix))
			if(!local_mix[id]) local_mix[id] = GLOB.gaslist_cache[id].Copy()
			if(!enemy_mix[id]) enemy_mix[id] = GLOB.gaslist_cache[id].Copy()

			var/local_gas = local_mix[id]
			var/enemy_gas = enemy_mix[id]
			var/delta = QUANTIZE(local_gas[ARCHIVE] - enemy_gas[ARCHIVE]) / k
			
			if(delta)
				if(!pair_delta[id]) pair_delta[id] = GLOB.gaslist_cache[id].Copy()
				//if(!total_delta[id]) total_delta[id] = 0
				
				var/gas_heat_capacity = delta * local_gas[GAS_META][META_GAS_SPECIFIC_HEAT]
				if(delta > 0)
					heat_capacity_self_to_sharer += gas_heat_capacity
				else
					heat_capacity_sharer_to_self -= gas_heat_capacity

				local_gas[MOLES] -= delta
				pair_delta[id][MOLES] = delta;
				//total_delta[id] -= delta;
				share += abs(delta)

				if(enemy_tile.atmo_state == ATMO_STATE_INACTIVE || enemy_tile.atmo_state == ATMO_STATE_REST)
					enemy_gas[MOLES] += delta

			else
				pair_delta -= id

		var/pair_change = FALSE
		for(var/id in pair_delta)
			if(abs(pair_delta[id][ARCHIVE] - pair_delta[id][MOLES]) > MINIMUM_MOLES_DELTA_TO_MOVE)
				pair_change = TRUE
				pair_delta[id][ARCHIVE] = pair_delta[id][MOLES] //by only updating this on change, prevents cumulative drift
			if(pair_delta[id][MOLES] == 0)
				pair_delta -= id

		var/new_self_heat_capacity = old_self_heat_capacity + heat_capacity_sharer_to_self - heat_capacity_self_to_sharer
		var/new_sharer_heat_capacity = old_sharer_heat_capacity + heat_capacity_self_to_sharer - heat_capacity_sharer_to_self
		if(new_self_heat_capacity > MINIMUM_HEAT_CAPACITY)
			local_air.temperature = (old_self_heat_capacity*temperature - heat_capacity_self_to_sharer*local_air.temperature_archived + heat_capacity_sharer_to_self*enemy_air.temperature_archived)/new_self_heat_capacity
		
		old_self_heat_capacity = new_self_heat_capacity

		if(enemy_tile.atmo_state == ATMO_STATE_INACTIVE || enemy_tile.atmo_state == ATMO_STATE_REST)
			if(new_sharer_heat_capacity > MINIMUM_HEAT_CAPACITY)
				enemy_air.temperature = (old_sharer_heat_capacity*enemy_air.temperature-heat_capacity_sharer_to_self*enemy_air.temperature_archived + heat_capacity_self_to_sharer*local_air.temperature_archived)/new_sharer_heat_capacity

		if(pair_change)
			enemy_tile.stability_counter = 0
			stability_counter = 0
			if(enemy_tile.atmo_state == ATMO_STATE_STABLE)
				enemy_tile.atmo_state = ATMO_STATE_ACTIVE
				enemy_tile.rest_counter = 0
				SSair.active_turfs |= enemy_tile
				ASSERT(SSair.currentpart == SSAIR_ACTIVETURFS) //shit needs to be taken care of THIS run, or we'll gain/lose significant atmo
				SSair.currentrun |= enemy_tile 
			

		//@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		//  grouping

		var/datum/excited_group/enemy_group = enemy_tile.excited_group
		if(local_group && enemy_group)
			if(local_group != enemy_group)
				//combine groups (this also handles updating the excited_group var of all involved turfs)
				local_group.merge_groups(enemy_group)
				local_group = excited_group //update our cache
#ifdef ASSERT_ACTIVE_TURFS
				ASSERT(local_group)
				ASSERT(src in local_group.turf_list)
				ASSERT(enemy_tile in local_group.turf_list)
				local_group.validate()
#endif

		else if(share > MINIMUM_MOLES_DELTA_TO_MOVE)
			if(enemy_tile.atmo_state != ATMO_STATE_ACTIVE)
				enemy_tile.atmo_state = ATMO_STATE_ACTIVE
				enemy_tile.stability_counter = 0
				enemy_tile.rest_counter = 0
				SSair.active_turfs |= enemy_tile
				if(enemy_tile.atmo_state == ATMO_STATE_STABLE)
					ASSERT(SSair.currentpart == SSAIR_ACTIVETURFS) //shit needs to be taken care of THIS run, or we'll gain/lose significant atmo
					SSair.currentrun |= enemy_tile
				else if(enemy_group)
					enemy_group.active_count++


			var/datum/excited_group/EG = local_group || enemy_group || new
			if(!local_group)
				EG.add_turf(src)
			if(!enemy_group)
				EG.add_turf(enemy_tile)
			local_group = excited_group
#ifdef ASSERT_ACTIVE_TURFS
			ASSERT(local_group)
			ASSERT(src in local_group.turf_list)
			ASSERT(enemy_tile in local_group.turf_list)
			local_group.validate()
#endif

		if(share > MINIMUM_AIR_TO_SUSPEND)
			if(enemy_tile.shared_this_tick < 2)
				enemy_tile.shared_this_tick = 2;
			if(shared_this_tick < 2)
				shared_this_tick = 2;
		else if(share > MINIMUM_MOLES_DELTA_TO_MOVE)
			if(enemy_tile.shared_this_tick < 1)
				enemy_tile.shared_this_tick = 1;
			if(shared_this_tick < 1)
				shared_this_tick = 1;

		/*
		if(difference)
			if(difference > 0)
				consider_pressure_difference(enemy_tile, difference)
			else
				enemy_tile.consider_pressure_difference(src, -difference)
		*/

#ifdef ASSERT_ACTIVE_TURFS
		if(local_group)
			ASSERT(src in local_group.turf_list)
			local_group.validate()
#endif

	//@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
	//  sharing atmosphere

	if (planet_atmos)
		var/datum/gas_mixture/enemy_air = new
		enemy_air.copy_from_turf(src)
		enemy_air.archive()

		var/list/enemy_mix = enemy_air.gases
		var/heat_capacity_sharer_to_self = 0
		var/heat_capacity_self_to_sharer = 0

		var/share = 0

		for(var/id in (enemy_mix || local_mix))
			if(!local_mix[id]) local_mix[id] = GLOB.gaslist_cache[id].Copy()
			if(!enemy_mix[id]) enemy_mix[id] = GLOB.gaslist_cache[id].Copy()

			var/local_gas = local_mix[id]
			var/enemy_gas = enemy_mix[id]
			var/delta = QUANTIZE(local_gas[ARCHIVE] - enemy_gas[ARCHIVE]) / local_k
			
			if(delta)
				//if(!total_delta[id]) total_delta[id] = 0
				
				var/gas_heat_capacity = delta * local_gas[GAS_META][META_GAS_SPECIFIC_HEAT]
				if(delta > 0)
					heat_capacity_self_to_sharer += gas_heat_capacity
				else
					heat_capacity_sharer_to_self -= gas_heat_capacity

				local_gas[MOLES] -= delta
				//total_delta[id] -= delta;
				share += abs(delta)

		var/new_self_heat_capacity = old_self_heat_capacity + heat_capacity_sharer_to_self - heat_capacity_self_to_sharer
		temperature = (old_self_heat_capacity*temperature - heat_capacity_self_to_sharer*temperature_archived + heat_capacity_sharer_to_self*enemy_air.temperature_archived)/new_self_heat_capacity

		old_self_heat_capacity = new_self_heat_capacity

		//@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		//  grouping atmosphere

		if(share > MINIMUM_MOLES_DELTA_TO_MOVE)
			if(!local_group)
				var/datum/excited_group/EG = new
				EG.add_turf(src)
				local_group = excited_group

		if(share > MINIMUM_AIR_TO_SUSPEND)
			if(shared_this_tick < 2)
				shared_this_tick = 2;
		else if(share > MINIMUM_MOLES_DELTA_TO_MOVE)
			if(shared_this_tick < 1)
				shared_this_tick = 1;
	
	//are we increasing significantly
	var/change = FALSE
	for(var/id in local_mix)
		if(abs(local_mix[id][MOLES] - local_mix[id][ARCHIVE]) > 0)
			change = TRUE
			break

	var/reacted = local_air.react(src) //TODO stable reaction fixing
	if(reacted || change) 
		stability_counter = 0

	stability_counter++

	if(reacted || shared_this_tick)
		rest_counter = 0
	else
		rest_counter++

	if(rest_counter >= 5)
		atmo_state = ATMO_STATE_REST
		local_group.active_count--
		SSair.active_turfs -= src
		if(SSair.currentpart == SSAIR_ACTIVETURFS)
			SSair.currentrun -= src
#ifdef VISUALIZE_ACTIVE_TURFS
		if(SSair.vis_activity)
			src.add_atom_colour("#006600", TEMPORARY_COLOUR_PRIORITY)
#endif

	else if(stability_counter >= 7)
		atmo_state = ATMO_STATE_STABLE
		SSair.active_turfs -= src
		if(SSair.currentpart == SSAIR_ACTIVETURFS)
			SSair.currentrun -= src
	
#ifdef VISUALIZE_ACTIVE_TURFS
		if(SSair.vis_activity)
			if(shared_this_tick == 2)
				src.add_atom_colour("#ff00ff", TEMPORARY_COLOUR_PRIORITY)
			else if(shared_this_tick == 1)
				src.add_atom_colour("#9900ff", TEMPORARY_COLOUR_PRIORITY)
			else
				src.add_atom_colour("#000066", TEMPORARY_COLOUR_PRIORITY)
#endif
	else
#ifdef VISUALIZE_ACTIVE_TURFS
		if(SSair.vis_activity)
			if(shared_this_tick == 2)
				src.add_atom_colour("#ffff00", TEMPORARY_COLOUR_PRIORITY)
			else if(shared_this_tick == 1)
				src.add_atom_colour("#ff9900", TEMPORARY_COLOUR_PRIORITY)
			else
				src.add_atom_colour("#660000", TEMPORARY_COLOUR_PRIORITY)
#endif

	update_visuals()

	//this was a dirty cleanup duct tape solution for turfs that didn't have their cooldown/excited unset correctly on group destruction
	//now it just cleans up single turfs that didn't share at all (like if they were effected by a breathe, but not enough to create a difference)
	if(!local_group && !(local_air.temperature > MINIMUM_TEMPERATURE_START_SUPERCONDUCTION && consider_superconductivity(starting = TRUE)))
		SSair.remove_from_active(src)

#ifdef VISUALIZE_ACTIVE_TURFS
		if(SSair.vis_activity)
			src.add_atom_colour("#000000", TEMPORARY_COLOUR_PRIORITY)
#endif

	shared_this_tick = 0

//////////////////////////SPACEWIND/////////////////////////////

/turf/open/proc/consider_pressure_difference(turf/T, difference)
	SSair.high_pressure_delta |= src
	if(difference > pressure_difference)
		pressure_direction = get_dir(src, T)
		pressure_difference = difference

/turf/open/proc/high_pressure_movements()
	var/atom/movable/M
	for(var/thing in src)
		M = thing
		if (!M.anchored && !M.pulledby && M.last_high_pressure_movement_air_cycle < SSair.times_fired)
			M.experience_pressure_difference(pressure_difference, pressure_direction)

/atom/movable/var/pressure_resistance = 10
/atom/movable/var/last_high_pressure_movement_air_cycle = 0

/atom/movable/proc/experience_pressure_difference(pressure_difference, direction, pressure_resistance_prob_delta = 0)
	var/const/PROBABILITY_OFFSET = 25
	var/const/PROBABILITY_BASE_PRECENT = 75
	var/max_force = sqrt(pressure_difference)*(MOVE_FORCE_DEFAULT / 5)
	set waitfor = 0
	var/move_prob = 100
	if (pressure_resistance > 0)
		move_prob = (pressure_difference/pressure_resistance*PROBABILITY_BASE_PRECENT)-PROBABILITY_OFFSET
	move_prob += pressure_resistance_prob_delta
	if (move_prob > PROBABILITY_OFFSET && prob(move_prob) && (move_resist != INFINITY) && (!anchored && (max_force >= (move_resist * MOVE_FORCE_PUSH_RATIO))) || (anchored && (max_force >= (move_resist * MOVE_FORCE_FORCEPUSH_RATIO))))
		step(src, direction)
		last_high_pressure_movement_air_cycle = SSair.times_fired

///////////////////////////EXCITED GROUPS/////////////////////////////

/datum/excited_group
	var/list/turf_list = list()
	var/rest_step = FALSE
	var/active_count = 0

/datum/excited_group/New()
	SSair.excited_groups += src

/datum/excited_group/proc/add_turf(turf/open/T)
#ifdef ASSERT_ACTIVE_TURFS
	ASSERT(T.excited_group == null)
	ASSERT(T.atmo_state == ATMO_STATE_ACTIVE)
#endif
	turf_list |= T
	T.excited_group = src
	active_count++
	rest_step = FALSE

/datum/excited_group/proc/validate()
	var/safety = 0
	for(var/t in turf_list)
		var/turf/open/T = t
		ASSERT(T.excited_group == src)
		ASSERT(T.atmo_state != ATMO_STATE_INACTIVE)
		if(T.atmo_state == ATMO_STATE_ACTIVE || T.atmo_state == ATMO_STATE_STABLE)
			safety++
	ASSERT(safety == active_count)

/datum/excited_group/proc/merge_groups(datum/excited_group/E)
	if(turf_list.len > E.turf_list.len)
		SSair.excited_groups -= E
		active_count += E.active_count
		for(var/t in E.turf_list)
			var/turf/open/T = t
			T.excited_group = src
			turf_list |= T
#ifdef ASSERT_ACTIVE_TURFS
		validate()
#endif
		E.turf_list.Cut()
		rest_step = FALSE
	else
		SSair.excited_groups -= src
		E.active_count += active_count
		for(var/t in turf_list)
			var/turf/open/T = t
			T.excited_group = E
			E.turf_list |= T
#ifdef ASSERT_ACTIVE_TURFS
		E.validate()
#endif
		turf_list.Cut()
		E.rest_step = FALSE

//argument is so world start can clear out any turf differences quickly.
/datum/excited_group/proc/self_breakdown(space_is_all_consuming = FALSE)
	var/datum/gas_mixture/A = new

	//make local for sanic speed
	var/list/A_gases = A.gases
	var/list/turf_list = src.turf_list
	var/turflen = turf_list.len

	for(var/t in turf_list)
		var/turf/open/T = t
		if (space_is_all_consuming && istype(T.air, /datum/gas_mixture/immutable/space))
			qdel(A)
			A = new /datum/gas_mixture/immutable/space()
			A_gases = A.gases //update the cache
			break
		A.merge(T.air)

	for(var/id in A_gases)
		A_gases[id][MOLES] /= turflen

	for(var/t in turf_list)
		var/turf/open/T = t
		T.air.copy_from(A)
		T.update_visuals()
		T.atmo_state = ATMO_STATE_ACTIVE
		T.stability_counter = 0
		T.rest_counter = 0
		SSair.active_turfs |= T
	active_count += turf_list.len

//called if the group should be destroyed and not continue running
/datum/excited_group/proc/decay()
	for(var/t in turf_list)
		var/turf/open/T = t
		T.excited_group = null
		T.atmo_state = ATMO_STATE_INACTIVE
		SSair.active_turfs -= T
		if(SSair.currentpart == SSAIR_ACTIVETURFS)
			SSair.currentrun -= T
#ifdef VISUALIZE_ACTIVE_TURFS
		if(SSair.vis_activity)
			T.add_atom_colour("#00aaff", TEMPORARY_COLOUR_PRIORITY)
#endif
	//we could lose atmo here due to unfinished shares
	active_count = 0
	turf_list.Cut()
	SSair.excited_groups -= src

//called if the group should be detroyed and recalculated
/datum/excited_group/proc/interupt()
	for(var/t in turf_list)
		var/turf/open/T = t
		T.excited_group = null
		T.atmo_state = ATMO_STATE_ACTIVE
		T.stability_counter = 0
		T.rest_counter = 0
		SSair.active_turfs |= T

	active_count = 0
	turf_list.Cut()
	SSair.excited_groups -= src

////////////////////////SUPERCONDUCTIVITY/////////////////////////////
/turf/proc/conductivity_directions()
	if(archived_cycle < SSair.times_fired)
		archive()
	return NORTH|SOUTH|EAST|WEST

/turf/open/conductivity_directions()
	if(blocks_air)
		return ..()
	for(var/direction in GLOB.cardinals)
		var/turf/T = get_step(src, direction)
		if(!(T in atmos_adjacent_turfs) && !(atmos_supeconductivity & direction))
			. |= direction

/turf/proc/neighbor_conduct_with_src(turf/open/other)
	if(!other.blocks_air) //Open but neighbor is solid
		other.temperature_share_open_to_solid(src)
	else //Both tiles are solid
		other.share_temperature_mutual_solid(src, thermal_conductivity)
	temperature_expose(null, temperature, null)

/turf/open/neighbor_conduct_with_src(turf/other)
	if(blocks_air)
		..()
		return

	if(!other.blocks_air) //Both tiles are open
		var/turf/open/T = other
		T.air.temperature_share(air, WINDOW_HEAT_TRANSFER_COEFFICIENT)
	else //Solid but neighbor is open
		temperature_share_open_to_solid(other)
	atmo_state = ATMO_STATE_ACTIVE
	SSair.add_to_active(src)

/turf/proc/super_conduct()
	var/conductivity_directions = conductivity_directions()

	if(conductivity_directions)
		//Conduct with tiles around me
		for(var/direction in GLOB.cardinals)
			if(conductivity_directions & direction)
				var/turf/neighbor = get_step(src,direction)

				if(!neighbor.thermal_conductivity)
					continue

				if(neighbor.archived_cycle < SSair.times_fired)
					neighbor.archive()

				neighbor.neighbor_conduct_with_src(src)

				neighbor.consider_superconductivity()

	radiate_to_spess()

	finish_superconduction()

/turf/proc/finish_superconduction(temp = temperature)
	//Make sure still hot enough to continue conducting heat
	if(temp < MINIMUM_TEMPERATURE_FOR_SUPERCONDUCTION)
		SSair.active_super_conductivity -= src
		return FALSE

/turf/open/finish_superconduction()
	//Conduct with air on my tile if I have it
	if(!blocks_air)
		temperature = air.temperature_share(null, thermal_conductivity, temperature, heat_capacity)
	..((blocks_air ? temperature : air.temperature))

/turf/proc/consider_superconductivity()
	if(!thermal_conductivity)
		return FALSE

	SSair.active_super_conductivity |= src
	return TRUE

/turf/open/consider_superconductivity(starting)
	if(air.temperature < (starting?MINIMUM_TEMPERATURE_START_SUPERCONDUCTION:MINIMUM_TEMPERATURE_FOR_SUPERCONDUCTION))
		return FALSE
	if(air.heat_capacity() < M_CELL_WITH_RATIO) // Was: MOLES_CELLSTANDARD*0.1*0.05 Since there are no variables here we can make this a constant.
		return FALSE
	return ..()

/turf/closed/consider_superconductivity(starting)
	if(temperature < (starting?MINIMUM_TEMPERATURE_START_SUPERCONDUCTION:MINIMUM_TEMPERATURE_FOR_SUPERCONDUCTION))
		return FALSE
	return ..()

/turf/proc/radiate_to_spess() //Radiate excess tile heat to space
	if(temperature > T0C) //Considering 0 degC as te break even point for radiation in and out
		var/delta_temperature = (temperature_archived - TCMB) //hardcoded space temperature
		if((heat_capacity > 0) && (abs(delta_temperature) > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER))

			var/heat = thermal_conductivity*delta_temperature* \
				(heat_capacity*HEAT_CAPACITY_VACUUM/(heat_capacity+HEAT_CAPACITY_VACUUM))
			temperature -= heat/heat_capacity

/turf/open/proc/temperature_share_open_to_solid(turf/sharer)
	sharer.temperature = air.temperature_share(null, sharer.thermal_conductivity, sharer.temperature, sharer.heat_capacity)

/turf/proc/share_temperature_mutual_solid(turf/sharer, conduction_coefficient) //to be understood
	var/delta_temperature = (temperature_archived - sharer.temperature_archived)
	if(abs(delta_temperature) > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER && heat_capacity && sharer.heat_capacity)

		var/heat = conduction_coefficient*delta_temperature* \
			(heat_capacity*sharer.heat_capacity/(heat_capacity+sharer.heat_capacity))

		temperature -= heat/heat_capacity
		sharer.temperature += heat/sharer.heat_capacity
