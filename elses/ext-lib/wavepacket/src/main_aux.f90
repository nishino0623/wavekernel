module wp_main_aux_m
  use mpi
  use wp_descriptor_parameters_m
  use wp_distribute_matrix_m
  use wp_processes_m
  use wp_fson_m
  use wp_fson_path_m
  use wp_fson_string_m
  use wp_fson_value_m
  use wp_event_logger_m
  use wp_atom_m
  use wp_charge_m
  use wp_conversion_m
  use wp_global_variables_m
  use wp_initialization_m
  use wp_linear_algebra_m
  use wp_matrix_generation_m
  use wp_output_m
  use wp_setting_m
  use wp_state_m
  use wp_time_evolution_m
  use wp_util_m
  implicit none

contains

  subroutine init_timers(wtime_total, wtime)
    real(8), intent(out) :: wtime_total, wtime
    integer :: ierr

    call mpi_barrier(mpi_comm_world, ierr)
    wtime_total = mpi_wtime()
    g_wp_mpi_wtime_init = wtime_total
    wtime = wtime_total
  end subroutine init_timers


  subroutine print_help_and_stop()
    integer :: ierr

    if (check_master()) then
      call print_help()
    end if
    call mpi_barrier(mpi_comm_world, ierr)
    call mpi_finalize(ierr)
    stop
  end subroutine print_help_and_stop


  subroutine add_timer_event(routine, event, wtime)
    character(*), intent(in) :: routine, event
    real(8), intent(inout) :: wtime

    real(8) :: wtime_end

    wtime_end = mpi_wtime()
    call add_event(routine // ':' // event, wtime_end - wtime)
    wtime = wtime_end
  end subroutine add_timer_event


  subroutine read_bcast_setting(setting, dim)
    type(wp_setting_t), intent(out) :: setting
    integer, intent(out) :: dim
    integer :: dim_overlap, num_atoms, num_groups, max_group_size, ierr

    if (check_master()) then
      call read_setting(setting)
      call inherit_setting(setting)

      call get_dimension(trim(setting%filename_hamiltonian), dim)
      if (.not. setting%is_overlap_ignored) then
        call get_dimension(trim(setting%filename_overlap), dim_overlap)
        if (dim /= dim_overlap) then
          call terminate('matrix sizes are inconsistent', ierr)
        end if
      end if

      if (trim(setting%filter_mode) == 'group') then
        call read_group_id_header(trim(setting%filter_group_filename), num_atoms, num_groups, max_group_size)
      end if

      call fill_filtering_setting(dim, num_groups, setting)
      call verify_setting(dim, setting)
      call print_setting(setting)
    end if
    call bcast_setting(g_wp_master_pnum, setting)
    call mpi_bcast(dim, 1, mpi_integer, g_wp_master_pnum, mpi_comm_world, ierr)
    call mpi_bcast(g_wp_block_size, 1, mpi_integer, g_wp_master_pnum, mpi_comm_world, ierr)
  end subroutine read_bcast_setting


  subroutine allocate_dv_vectors(setting, state)
    type(wp_setting_t), intent(in) :: setting
    type(wp_state_t), intent(inout) :: state

    integer :: n, a

    n = setting%num_filter
    a = state%structure%num_atoms
    allocate(state%dv_alpha(n), state%dv_psi(state%dim), state%dv_alpha_next(n), state%dv_psi_next(state%dim))
    allocate(state%dv_alpha_reconcile(n), state%dv_psi_reconcile(state%dim))
    allocate(state%dv_atom_perturb(a), state%dv_atom_speed(a))
    allocate(state%dv_charge_on_basis(state%dim), state%dv_charge_on_atoms(a))
    allocate(state%dv_eigenvalues(n), state%dv_ipratios(n))
    allocate(state%eigenstate_mean(3, n), state%eigenstate_msd(4, n))
    allocate(state%eigenstate_ipratios(setting%num_filter))
  end subroutine allocate_dv_vectors


  subroutine setup_distributed_matrices(dim, setting, proc, state)
    integer, intent(in) :: dim
    type(wp_setting_t), intent(in) :: setting
    type(wp_process_t), intent(in) :: proc
    type(wp_state_t), intent(inout) :: state
    ! The parameters below are in 'state'.
    !integer, intent(out) :: Y_desc(desc_size), Y_filtered_desc(desc_size)
    !integer, intent(out) :: H1_desc(desc_size), A_desc(desc_size)
    !real(8), allocatable, intent(out) :: Y(:, :)  ! m x m
    !real(8), allocatable, intent(out) :: H1_multistep(:, :)
    !real(8), allocatable, intent(out) :: Y_filtered(:, :)  ! m x n
    !real(8), allocatable, intent(out) :: H1(:, :), H1_base(:, :)
    !complex(kind(0d0)), allocatable, intent(out) :: A(:, :)  ! n x n

    integer :: ierr

    if (check_master()) then
      call print_proc(proc)
    end if

    if (setting%is_reduction_mode) then
      call terminate('setup_distributed_matrices: reduction mode is not implemented in this version', 1)
    end if
    if (.not. setting%to_replace_basis) then
      call setup_distributed_matrix_real('H1_multistep', proc, &
           setting%num_filter, setting%num_filter, state%H1_desc, state%H1_multistep, .true.)
    end if
    call setup_distributed_matrix_real('Y', proc, state%dim, state%dim, state%Y_desc, state%Y, .true.)
    call setup_distributed_matrix_real('Y_filtered', proc, &
         state%dim, setting%num_filter, state%Y_filtered_desc, state%Y_filtered)
    call setup_distributed_matrix_real('H1', proc, &
         setting%num_filter, setting%num_filter, state%H1_desc, state%H1, .true.)
    if (trim(setting%filter_mode) == 'group') then
      call setup_distributed_matrix_real('H1_base', proc, &
           setting%num_filter, setting%num_filter, state%H1_desc, state%H1_base, .true.)
    end if
    call setup_distributed_matrix_complex('A', proc, &
         setting%num_filter, setting%num_filter, state%A_desc, state%A, .true.)
    call setup_distributed_matrix_real('YSY_filtered', proc, &
         setting%num_filter, setting%num_filter, state%YSY_filtered_desc, state%YSY_filtered)
  end subroutine setup_distributed_matrices


  ! read_matrix_file は allocation も同時に行う
  subroutine read_bcast_matrix_files(dim, setting, step, H_sparse, S_sparse)
    integer, intent(in) :: dim, step
    type(wp_setting_t), intent(in) :: setting
    type(sparse_mat), intent(inout) :: H_sparse, S_sparse

    real(8) :: wtime

    wtime = mpi_wtime()

    call destroy_sparse_mat(H_sparse)
    call destroy_sparse_mat(S_sparse)
    call add_timer_event('read_bcast_matrix_files', 'destroy_sparse_matrices', wtime)
    if (check_master()) then
      call read_matrix_file(trim(setting%filename_hamiltonian), step, H_sparse)
      call add_timer_event('read_bcast_matrix_files', 'read_matrix_file_H', wtime)
      if (setting%is_overlap_ignored) then
        call set_sparse_matrix_identity(dim, S_sparse)
        call add_timer_event('read_bcast_matrix_files', 'set_sparse_matrix_identity', wtime)
      else
        call read_matrix_file(trim(setting%filename_overlap), step, S_sparse)
        call add_timer_event('read_bcast_matrix_files', 'read_matrix_file_S', wtime)
      end if
    end if
    call bcast_sparse_matrix(g_wp_master_pnum, H_sparse)
    call bcast_sparse_matrix(g_wp_master_pnum, S_sparse)
    call add_timer_event('read_bcast_matrix_files', 'bcast_sparse_matrices', wtime)
  end subroutine read_bcast_matrix_files


  subroutine set_aux_matrices(dim, setting, proc, state, &
       to_use_precomputed_eigenpairs, eigenvalues, desc_eigenvectors, eigenvectors)
    integer, intent(in) :: dim
    type(wp_setting_t), intent(in) :: setting
    type(wp_process_t), intent(in) :: proc
    type(wp_state_t), intent(inout) :: state
    ! The commented out parameters below are in 'state'.
    !type(wp_structure_t), intent(in) :: structure
    !type(sparse_mat), intent(in) :: H_sparse, S_sparse, H_multistep_sparse, S_multistep_sparse
    !integer, intent(in) :: H1_desc(desc_size), Y_desc(desc_size), Y_filtered_desc(desc_size)
    !integer, intent(in) :: filter_group_id(:, :)
    !real(8), intent(out) :: Y(:, :), Y_filtered(:, :), H1_base(:, :), dv_eigenvalues(:), dv_ipratios(:)
    !real(8), intent(out) :: eigenstate_mean(:, :), eigenstate_msd(:, :)
    !type(wp_local_matrix_t), allocatable, intent(out) :: Y_local(:)
    !integer, allocatable, intent(out) :: filter_group_indices(:, :)
    logical, intent(in) :: to_use_precomputed_eigenpairs
    integer, intent(in) :: desc_eigenvectors(desc_size)
    real(8), intent(in) :: eigenvalues(:), eigenvectors(:, :)

    integer :: end_filter, ierr
    real(8), allocatable :: eigenstate_charges(:, :)
    real(8) :: wtime

    wtime = mpi_wtime()

    if (setting%is_reduction_mode) then
      call terminate('set_aux_matrices: reduction mode is not implemented in this version', 1)
    end if

    if (check_master()) then
      write (0, '(A, F16.6, A)') ' [Event', mpi_wtime() - g_wp_mpi_wtime_init, &
           '] set_eigenpairs() start '
    end if

    if (to_use_precomputed_eigenpairs) then
      if (size(eigenvalues, 1) /= state%dim) then
        call terminate('wrong size of eigenvalues', 1)
      end if
      if (desc_eigenvectors(rows_) /= dim .or. desc_eigenvectors(cols_) /= dim) then
        call terminate('wrong size of eigenvectors', 1)
      end if
      end_filter = setting%fst_filter + setting%num_filter - 1
      state%dv_eigenvalues(1 : setting%num_filter) = eigenvalues(setting%fst_filter : end_filter)
      call pdgemr2d(state%dim, setting%num_filter, &
           eigenvectors, 1, setting%fst_filter, desc_eigenvectors, &
           state%Y_filtered, 1, 1, state%Y_filtered_desc, &
           state%Y_filtered_desc(context_))
    else
      call set_eigenpairs(state%dim, setting, proc, state%filter_group_id, state%structure, &
           state%H_sparse, state%S_sparse, state%Y_desc, state%Y, &
           state%dv_eigenvalues, state%Y_filtered_desc, state%Y_filtered, state%filter_group_indices)
    end if
    call add_timer_event('set_aux_matrices', 'set_eigenpairs', wtime)

    allocate(eigenstate_charges(size(state%group_id, 2), setting%num_filter))
    call get_eigenstate_charges_on_groups(state%Y_filtered, state%Y_filtered_desc, &
         state%structure, state%group_id, eigenstate_charges, state%eigenstate_ipratios)
    deallocate(eigenstate_charges)
    call add_timer_event('set_aux_matrices', 'get_eigenstate_charges_on_groups', wtime)

    call clear_offdiag_blocks_of_overlap(setting, state%filter_group_indices, state%S_sparse)
    call add_timer_event('set_aux_matrices', 'clear_offdiag_blocks_of_overlap', wtime)

    if (setting%filter_mode == 'group') then
      call set_local_eigenvectors(proc, state%Y_filtered_desc, &
           state%Y_filtered, state%filter_group_indices, state%Y_local)
    end if
    call add_timer_event('set_aux_matrices', 'set_local_eigenvectors', wtime)

    if (setting%filter_mode == 'group') then
      call set_H1_base(proc, state%filter_group_indices, state%Y_local, &
           state%H_sparse, state%H1_base, state%H1_desc)
    end if
    call add_timer_event('set_aux_matrices', 'set_H1_base', wtime)

    if (check_master()) then
      write (0, '(A, F16.6, A)') ' [Event', mpi_wtime() - g_wp_mpi_wtime_init, &
           '] get_msd_of_eigenstates() start '
    end if

    call get_msd_of_eigenstates(state%structure, state%S_sparse, state%Y_filtered, state%Y_filtered_desc, &
         state%eigenstate_mean, state%eigenstate_msd)
    call get_ipratio_of_eigenstates(state%Y_filtered, state%Y_filtered_desc, state%dv_ipratios)
    call add_timer_event('set_aux_matrices', 'get_msd_and_ipratio', wtime)
  end subroutine set_aux_matrices


  !subroutine set_aux_matrices_for_multistep(dim, setting, proc, filter_group_id, t, structure, charge_factor, &
  !         H_sparse, S_sparse, Y_desc, Y, Y_filtered_desc, Y_filtered, &
  !         H_multistep_sparse, S_multistep_sparse, &
  !         H1_desc, H1, H1_base, H1_multistep, &
  !         filter_group_indices, Y_local, &
  !         dv_psi, dv_alpha, dv_psi_reconcile, dv_alpha_reconcile, &
  !         dv_charge_on_basis, dv_charge_on_atoms, dv_eigenvalues, &
  !         charge_moment, energies, errors, &
  !         to_use_precomputed_eigenpairs, eigenvalues, desc_eigenvectors, eigenvectors)
  subroutine set_aux_matrices_for_multistep(setting, proc, &
       to_use_precomputed_eigenpairs, eigenvalues, desc_eigenvectors, eigenvectors, state)
    type(wp_setting_t), intent(in) :: setting
    type(wp_process_t), intent(in) :: proc
    integer, intent(in) :: desc_eigenvectors(desc_size)
    logical, intent(in) :: to_use_precomputed_eigenpairs
    real(8), intent(in) :: eigenvalues(:), eigenvectors(:, :)
    type(wp_state_t), intent(inout) :: state
    ! The commented out parameters below are in 'state'.
    !integer, intent(in) :: dim, filter_group_id(:, :)
    !type(wp_structure_t), intent(in) :: structure
    !real(8), intent(in) :: t
    !type(wp_charge_factor_t), intent(in) :: charge_factor
    !integer, allocatable, intent(inout) :: filter_group_indices(:, :)
    !type(sparse_mat), intent(in) :: H_sparse, S_sparse
    !type(sparse_mat), intent(inout) :: H_multistep_sparse, S_multistep_sparse
    !integer, intent(in) :: Y_desc(desc_size), Y_filtered_desc(desc_size), H1_desc(desc_size)
    !real(8), intent(inout) :: Y_filtered(:, :)  ! value of last step is needed for offdiag norm calculation.
    !real(8), intent(out) :: Y(:, :), H1(:, :), H1_base(:, :)
    !real(8), intent(out) :: H1_multistep(:, :)
    !complex(kind(0d0)), intent(in) :: dv_psi(:), dv_alpha(:)
    !complex(kind(0d0)), intent(out) :: dv_psi_reconcile(:), dv_alpha_reconcile(:)
    !real(8), intent(out) :: dv_charge_on_basis(:), dv_charge_on_atoms(:), dv_eigenvalues(:)
    !type(wp_local_matrix_t), allocatable, intent(out) :: Y_local(:)
    !type(wp_charge_moment_t), intent(out) :: charge_moment
    !type(wp_energy_t), intent(out) :: energies
    !type(wp_error_t), intent(out) :: errors

    real(8) :: wtime

    wtime = mpi_wtime()

    if (setting%to_replace_basis) then
      call read_next_input_step_with_basis_replace(state%dim, setting, proc, &
           state%group_id, state%filter_group_id, state%t, state%structure, &
           state%H_sparse, state%S_sparse, state%Y_desc, state%Y, state%Y_filtered_desc, state%Y_filtered, &
           state%YSY_filtered_desc, state%YSY_filtered, &
           state%H1_desc, state%H1, state%H1_base, &
           state%filter_group_indices, state%Y_local, state%charge_factor, &
           state%dv_psi, state%dv_alpha, state%dv_psi_reconcile, state%dv_alpha_reconcile, &
           state%dv_charge_on_basis, state%dv_charge_on_atoms, state%dv_eigenvalues, &
           state%charge_moment, state%energies, state%errors, state%eigenstate_ipratios, &
           to_use_precomputed_eigenpairs, eigenvalues, desc_eigenvectors, eigenvectors)
      call add_timer_event('set_aux_matrices_for_multistep', 'read_next_input_step_with_basis_replace', wtime)
      if (check_master()) then
        write (0, '(A, F16.6, A, E26.16e3, A, E26.16e3, A)') ' [Event', mpi_wtime() - g_wp_mpi_wtime_init, &
             '] psi error after re-initialization is ', state%errors%absolute, &
             ' (absolute) and ', state%errors%relative, ' (relative)'
      end if
    else
      ! implementation may be incorrect
      call read_next_input_step_matrix(setting, &
           state%S_multistep_sparse, &
           state%filter_group_indices)
      call add_timer_event('set_aux_matrices_for_multistep', 'read_next_input_step_matrix', wtime)
      !H_multistep(:, :) = H_multistep(:, :) - H(:, :)  ! sparse matrix subtract is not implemented
      !call make_H1_multistep(proc, Y_filtered, Y_filtered_desc, H_multistep, H_desc, &
      !     trim(setting%filter_mode) == 'group', filter_group_indices, Y_local, &
      !     H1_multistep, H1_desc)
      call terminate('set_aux_matrices_for_multistep:make_H1_multistep not implemented in this version', 1)
      call add_timer_event('set_aux_matrices_for_multistep', 'make_H1_multistep', wtime)
    end if
  end subroutine set_aux_matrices_for_multistep


  subroutine read_bcast_structure(dim, setting, step, structure)
    integer, intent(in) :: dim, step
    type(wp_setting_t), intent(in) :: setting
    type(wp_structure_t), intent(out) :: structure

    if (allocated(structure%atom_indices)) then
      deallocate(structure%atom_indices)
    end if
    if (allocated(structure%atom_coordinates)) then
      deallocate(structure%atom_coordinates)
    end if
    if (allocated(structure%atom_elements)) then
      deallocate(structure%atom_elements)
    end if

    if (check_master()) then
      if (setting%is_atom_indices_enabled) then
        call read_structure(setting%atom_indices_filename, step, structure)
      else
        call make_dummy_structure(dim, structure)
      end if
    end if
    call bcast_structure(g_wp_master_pnum, structure)
    if (structure%atom_indices(structure%num_atoms + 1) - 1 /= dim) then
      stop 'invalid atom index file'
    else if (setting%is_restart_mode .and. trim(setting%h1_type) == 'maxwell') then
      if (size(setting%restart_atom_speed) /= structure%num_atoms) then
        stop 'dimension of the atom_speed in the restart file is not equal to num_atoms'
      end if
    else if (setting%is_restart_mode .and. trim(setting%h1_type) == 'harmonic') then
      if (size(setting%restart_atom_perturb) /= structure%num_atoms) then
        stop 'dimension of the atom_perturb in the restart file is not equal to num_atoms'
      end if
    end if
  end subroutine read_bcast_structure


  subroutine read_bcast_group_id(filename, group_id)
    character(len=*), intent(in) :: filename
    integer, allocatable, intent(out) :: group_id(:, :)

    if (check_master()) then
      call read_group_id(trim(filename), group_id)
    end if
    call bcast_group_id(g_wp_master_pnum, group_id)
  end subroutine read_bcast_group_id


  subroutine set_eigenpairs(dim, setting, proc, filter_group_id, structure, H_sparse, S_sparse, Y_desc, Y, &
       dv_eigenvalues_filtered, Y_filtered_desc, Y_filtered, filter_group_indices)
    integer, intent(in) :: dim
    type(wp_setting_t), intent(in) :: setting
    type(wp_process_t), intent(in) :: proc
    integer, intent(in) :: filter_group_id(:, :)
    type(wp_structure_t), intent(in) :: structure
    type(sparse_mat), intent(in) :: H_sparse, S_sparse
    integer, intent(in) :: Y_desc(desc_size), Y_filtered_desc(desc_size)
    integer, allocatable, intent(out) :: filter_group_indices(:, :)
    real(8), intent(out) :: dv_eigenvalues_filtered(:)
    real(8), intent(inout) :: Y_filtered(:, :)  ! value of last step is needed for offdiag norm calculation.

    integer :: i, j, num_groups, atom_min, atom_max, index_min, index_max, dim_sub, Y_sub_desc(desc_size)
    integer :: homo_level, filter_lowest_level, base_index_of_group, sum_dim_sub
    integer :: H_desc(desc_size), S_desc(desc_size)
    real(8) ::  Y(:, :), elem
    real(8) :: dv_eigenvalues(dim), wtime
    integer :: YSY_desc(desc_size)
    real(8), allocatable :: H(:, :), S(:, :), Y_sub(:, :), Y_filtered_last(:, :), SY(:, :), YSY(:, :)
    real(8), allocatable ::  eigenvalues_sub(:)

    wtime = mpi_wtime()

    call setup_distributed_matrix_real('H', proc, dim, dim, H_desc, H, .true.)
    call setup_distributed_matrix_real('S', proc, dim, dim, S_desc, S, .true.)
    call distribute_global_sparse_matrix_wp(H_sparse, H_desc, H)
    call distribute_global_sparse_matrix_wp(S_sparse, S_desc, S)

    if (setting%to_use_precomputed_eigenpairs .or. setting%filter_mode == 'all') then  ! Temporary condition.
      allocate(Y_filtered_last(size(Y_filtered, 1), size(Y_filtered, 2)), &
           SY(size(Y_filtered, 1), size(Y_filtered, 2)))
      call setup_distributed_matrix_real('YSY', proc, setting%num_filter, setting%num_filter, YSY_desc, YSY)
      Y_filtered_last(:, :) = Y_filtered(:, :)
      call add_timer_event('set_eigenpairs', 'prepare_matrices_for_offdiag_norm_calculation', wtime)
    end if

    if (setting%to_use_precomputed_eigenpairs) then
      call terminate('not implemented', 44)
      !! read_distribute_eigen* are written in 'read at master -> broadcast' style.
      !call read_distribute_eigenvalues(setting%eigenvalue_filename, dim, &
      !     full_vecs, col_eigenvalues, full_vecs_desc)
      !call read_distribute_eigenvectors(setting%eigenvector_dirname, dim, &
      !     setting%fst_filter, setting%num_filter, &
      !     Y_filtered, Y_filtered_desc)
      !! Filter eigenvalues.
      !call pzgemr2d(setting%num_filter, 1, &
      !     full_vecs, setting%fst_filter, col_eigenvalues, full_vecs_desc, &
      !     filtered_vecs, 1, col_eigenvalues_filtered, filtered_vecs_desc, &
      !     full_vecs_desc(context_))
      !call add_timer_event('set_eigenpairs', 'read_and_distribute_eigenpairs', wtime)
    else if (setting%filter_mode == 'all') then
      call solve_gevp(dim, 1, proc, H, H_desc, S, S_desc, dv_eigenvalues, Y, Y_desc)
      call add_timer_event('set_eigenpairs', 'solve_gevp_in_filter_all', wtime)
      ! Filter eigenvalues.
      dv_eigenvalues_filtered(1 : setting%num_filter) = &
           dv_eigenvalues(setting%fst_filter : setting%fst_filter + setting%num_filter - 1)
      ! Filter eigenvectors.
      call pdgemr2d(dim, setting%num_filter, &
           Y, 1, setting%fst_filter, Y_desc, &
           Y_filtered, 1, 1, Y_filtered_desc, &
           Y_desc(context_))
      call add_timer_event('set_eigenpairs', 'copy_filtering_eigenvectors_in_filter_all', wtime)
    else if (setting%filter_mode == 'group') then
      call terminate('not implemented', 45)
      !num_groups = size(filter_group_id, 2)
      !index_max = 0  ! Initialization for overlap checking.
      !sum_dim_sub = 0
      !if (allocated(filter_group_indices)) then
      !  deallocate(filter_group_indices)
      !end if
      !allocate(filter_group_indices(2, num_groups + 1))
      !call add_timer_event('set_eigenpairs', 'allocate_in_filter_group', wtime)
      !!print *, 'E', atom_indices
      !do i = 1, num_groups  ! Assumes that atoms in a group have successive indices.
      !  if (check_master()) then
      !    write (0, '(A, F16.6, A, I0, A)') ' [Event', mpi_wtime() - g_wp_mpi_wtime_init, &
      !         '] solve_gevp: solve group ', i, ' start'
      !  end if
      !  atom_min = dim
      !  atom_max = 0
      !  do j = 2, filter_group_id(1, i) + 1
      !    atom_min = min(atom_min, filter_group_id(j, i))
      !    atom_max = max(atom_max, filter_group_id(j, i))
      !  end do
      !  index_min = atom_indices(atom_min)
      !  if (index_min <= index_max) then
      !    call terminate('indeices for groups are overlapping', 1)
      !  end if
      !  index_max = atom_indices(atom_max + 1) - 1
      !  dim_sub = index_max - index_min + 1
      !
      !  call setup_distributed_matrix_complex('Y_sub', proc, dim_sub, dim_sub, Y_sub_desc, Y_sub, .true.)
      !  allocate(eigenvalues_sub(dim_sub))
      !  call add_timer_event('set_eigenpairs', 'setup_indices_and_distributed_matrix_in_filter_group', wtime)
      !
      !  call solve_gevp(dim_sub, index_min, proc, H, H_desc, S, S_desc, eigenvalues_sub, Y_sub, Y_sub_desc)
      !  call add_timer_event('set_eigenpairs', 'solve_gevp_in_filter_group', wtime)
      !
      !  homo_level = (dim_sub + 1) / 2
      !  filter_lowest_level = homo_level - setting%num_group_filter_from_homo + 1
      !  base_index_of_group = (i - 1) * setting%num_group_filter_from_homo
      !  !print *, 'Q', atom_min, atom_max, index_min, index_max, dim_sub, filter_lowest_level, base_index_of_group
      !  do j = filter_lowest_level, homo_level
      !    elem = eigenvalues_sub(j)
      !    call pzelset(filtered_vecs, base_index_of_group + j - filter_lowest_level + 1, &
      !         col_eigenvalues_filtered, filtered_vecs_desc, elem)
      !  end do
      !  call add_timer_event('set_eigenpairs', 'filter_eigenvalues_in_filter_group', wtime)
      !  ! Filter eigenvectors (eigenvalues are already filtered).
      !
      !  !if (check_master()) then
      !  !  print *, 'W', homo_level, filter_lowest_level, base_index_of_group, sum_dim_sub
      !  !end if
      !
      !  call pzgemr2d(dim_sub, setting%num_group_filter_from_homo, &
      !       Y_sub, 1, filter_lowest_level, Y_sub_desc, &
      !       Y_filtered, sum_dim_sub + 1, base_index_of_group + 1, Y_filtered_desc, &
      !       Y_desc(context_))
      !  filter_group_indices(1, i) = sum_dim_sub + 1
      !  filter_group_indices(2, i) = base_index_of_group + 1
      !  sum_dim_sub = sum_dim_sub + dim_sub
      !  deallocate(Y_sub, eigenvalues_sub)
      !  call add_timer_event('set_eigenpairs', 'filter_eigenvectors_in_filter_group', wtime)
      !end do
      !filter_group_indices(1, num_groups + 1) = dim + 1
      !filter_group_indices(2, num_groups + 1) = setting%num_filter + 1
    end if

    ! calculate norm of offdiag part of Y' S' Y, where Y' and S' are in present step and Y is in previous step.
    if (setting%to_use_precomputed_eigenpairs .or. setting%filter_mode == 'all') then  ! Temporary condition.
      !call pzgemm('No', 'No', dim, setting%num_filter, dim, kOne, &
      !     S, 1, 1, S_desc, &
      !     Y_filtered_last, 1, 1, Y_filtered_desc, &
      !     kZero, SY, 1, 1, Y_filtered_desc)
      !call pzgemm('Conjg', 'No', setting%num_filter, setting%num_filter, dim, kOne, &
      !     Y_filtered, 1, 1, Y_filtered_desc, &
      !     SY, 1, 1, Y_filtered_desc, &
      !     kZero, YSY, 1, 1, YSY_desc)
      !call print_offdiag_norm('YSY', YSY, YSY_desc)
      !call add_timer_event('set_eigenpairs', 'calculate_offdiag_norm', wtime)
    end if

    deallocate(H, S)
  end subroutine set_eigenpairs


  subroutine set_local_eigenvectors(proc, Y_filtered_desc, Y_filtered, filter_group_indices, Y_local)
    integer, intent(in) :: Y_filtered_desc(desc_size), filter_group_indices(:, :)
    type(wp_process_t), intent(in) :: proc
    real(8), intent(in) :: Y_filtered(:, :)
    type(wp_local_matrix_t), allocatable, intent(out) :: Y_local(:)
    integer :: g, num_groups, i, j, m, n, p, nprow, npcol, myp, myprow, mypcol, np, prow, pcol
    integer :: blacs_pnum
    real(8) :: wtime

    wtime = mpi_wtime()

    num_groups = size(filter_group_indices, 2) - 1
    call blacs_gridinfo(proc%context, nprow, npcol, myprow, mypcol)
    np = nprow * npcol
    if (num_groups > np) then
      call terminate('the number of processes must be the number of groups or more', 1)
    end if
    myp = blacs_pnum(proc%context, myprow, mypcol)
    do g = 1, num_groups
      p = g - 1  ! Destination process.
      call blacs_pcoord(proc%context, p, prow, pcol)
      i = filter_group_indices(1, g)
      j = filter_group_indices(2, g)
      m = filter_group_indices(1, g + 1) - i
      n = filter_group_indices(2, g + 1) - j
      if (p == myp) then
        if (allocated(Y_local)) then
          deallocate(Y_local(1)%val)
          deallocate(Y_local)
        end if
        allocate(Y_local(1)%val(m, n))  ! Temporary implementation:
      end if
      call gather_matrix_real_part(Y_filtered, Y_filtered_desc, i, j, m, n, prow, pcol, Y_local(1)%val)
    end do

    call add_timer_event('set_local_eigenvectors', 'set_local_eigenvectors', wtime)
  end subroutine set_local_eigenvectors


  subroutine set_H1_base(proc, filter_group_indices, Y_local, H_sparse, H1_base, H1_desc)
    type(wp_process_t), intent(in) :: proc
    integer, intent(in) :: filter_group_indices(:, :), H1_desc(desc_size)
    type(sparse_mat), intent(in) :: H_sparse
    type(wp_local_matrix_t), intent(in) :: Y_local(:)
    real(8), intent(out) :: H1_base(:, :)

    call change_basis_lcao_to_alpha_group_filter(proc, filter_group_indices, Y_local, &
         H_sparse, H1_base, H1_desc, .true.)
  end subroutine set_H1_base


  subroutine clear_offdiag_blocks_of_overlap(setting, filter_group_indices, S_sparse)
    type(wp_setting_t), intent(in) :: setting
    integer, intent(in) :: filter_group_indices(:, :)
    type(sparse_mat) :: S_sparse

    if (trim(setting%filter_mode) == 'group') then
      call clear_offdiag_blocks(filter_group_indices, S_sparse)
    end if
  end subroutine clear_offdiag_blocks_of_overlap


  subroutine prepare_json(setting, proc, state)
    type(wp_setting_t), intent(in) :: setting
    type(wp_process_t), intent(in) :: proc
    type(wp_state_t), intent(inout) :: state
    ! The commented out parameters below are in 'state'.
    !integer, intent(in) :: dim
    !type(wp_structure_t), intent(in) :: structure
    !type(wp_error_t), intent(in) :: errors
    !integer, intent(in) :: group_id(:, :), filter_group_id(:, :)
    !real(8), intent(in) :: eigenstate_mean(3, setting%num_filter), eigenstate_msd(4, setting%num_filter)
    !real(8), intent(in) :: dv_eigenvalues(:), dv_ipratios(:)
    !type(fson_value), pointer, intent(out) :: output, states, structures, split_files_metadata
    integer :: i, master_prow, master_pcol, iunit_header
    type(fson_value), pointer :: split_files_metadata_elem

    if (check_master()) then
      write (0, '(A, F16.6, A)') ' [Event', mpi_wtime() - g_wp_mpi_wtime_init, &
           '] prepare_json(): start'
    end if

    ! Create whole output fson object.
    state%output => fson_value_create()
    state%output%value_type = TYPE_OBJECT
    call add_setting_json(setting, proc, state%output)
    if (check_master()) then
      call add_condition_json(state%dim, setting, state%structure, state%errors, &
           state%group_id, state%filter_group_id, &
           state%dv_eigenvalues, state%eigenstate_mean, state%eigenstate_msd, state%dv_ipratios, state%output)
      open(iunit_header, file=trim(add_postfix_to_filename(setting%output_filename, '_header')))
      call fson_print(iunit_header, state%output)
      close(iunit_header)
    end if

    state%states => fson_value_create()
    call fson_set_name('states', state%states)
    state%states%value_type = TYPE_ARRAY
    state%structures => fson_value_create()
    call fson_set_name('structures', state%structures)
    state%structures%value_type = TYPE_ARRAY

    if (setting%is_output_split) then
      state%split_files_metadata => fson_value_create()
      call fson_set_name('split_files_metadata', state%split_files_metadata)
      state%split_files_metadata%value_type = TYPE_ARRAY
      if (setting%is_restart_mode) then
        do i = 1, size(setting%restart_split_files_metadata)
          split_files_metadata_elem => fson_value_create()
          call fson_set_as_string(trim(setting%restart_split_files_metadata(i)), split_files_metadata_elem)
          call fson_value_add(state%split_files_metadata, split_files_metadata_elem)
        end do
      end if
    end if
  end subroutine prepare_json


  subroutine read_next_input_step_with_basis_replace(dim, setting, proc, group_id, filter_group_id, t, structure, &
       H_sparse, S_sparse, Y_desc, Y, Y_filtered_desc, Y_filtered, YSY_filtered_desc, YSY_filtered, &
       H1_desc, H1, H1_base, &
       filter_group_indices, Y_local, charge_factor, &
       dv_psi, dv_alpha, dv_psi_reconcile, dv_alpha_reconcile, &
       dv_charge_on_basis, dv_charge_on_atoms, dv_eigenvalues, &
       charge_moment, energies, errors, eigenstate_ipratios, &
       to_use_precomputed_eigenpairs, eigenvalues, desc_eigenvectors, eigenvectors)
    integer, intent(in) :: dim, group_id(:, :), filter_group_id(:, :)
    type(wp_process_t), intent(in) :: proc
    type(wp_setting_t), intent(in) :: setting
    real(8), intent(in) :: t
    type(wp_structure_t), intent(in) :: structure
    type(wp_charge_factor_t), intent(in) :: charge_factor
    integer, allocatable, intent(inout) :: filter_group_indices(:, :)
    type(sparse_mat), intent(in) :: H_sparse, S_sparse
    integer, intent(in) :: Y_desc(desc_size), Y_filtered_desc(desc_size), YSY_filtered_desc(desc_size)
    integer, intent(in) :: H1_desc(desc_size), desc_eigenvectors(desc_size)
    ! value of last step is needed for offdiag norm calculation.
    real(8), intent(inout) :: dv_eigenvalues(:), Y_filtered(:, :)
    real(8), intent(out) :: Y(:, :), YSY_filtered(:, :), H1(:, :), H1_base(:, :)
    real(8), intent(out) :: dv_charge_on_basis(:), dv_charge_on_atoms(:)
    complex(kind(0d0)), intent(in) :: dv_psi(:), dv_alpha(:)
    complex(kind(0d0)), intent(out) :: dv_psi_reconcile(:), dv_alpha_reconcile(:)
    type(wp_local_matrix_t), allocatable, intent(out) :: Y_local(:)
    type(wp_charge_moment_t), intent(out) :: charge_moment
    type(wp_energy_t), intent(out) :: energies
    type(wp_error_t), intent(out) :: errors
    real(8), intent(out) :: eigenstate_ipratios(:)
    logical, intent(in) :: to_use_precomputed_eigenpairs
    real(8), intent(in) :: eigenvalues(:), eigenvectors(:, :)

    integer :: end_filter, S_desc(desc_size), SY_desc(desc_size)
    real(8) :: dv_eigenvalues_prev(setting%num_filter)
    real(8), allocatable :: eigenstate_charges(:, :), S(:, :), SY(:, :)
    real(8) :: wtime

    wtime = mpi_wtime()

    call clear_offdiag_blocks_of_overlap(setting, filter_group_indices, S_sparse)
    call add_timer_event('read_next_input_step_with_basis_replace', 'clear_offdiag_blocks_of_overlap', wtime)

    dv_eigenvalues_prev(:) = dv_eigenvalues(:)
    if (trim(setting%re_initialize_method) == 'minimize_lcao_error_matrix_suppress') then
      call setup_distributed_matrix_real('S', proc, dim, dim, S_desc, S, .true.)
      call distribute_global_sparse_matrix_wp(S_sparse, S_desc, S)
      call setup_distributed_matrix_real('SY', proc, dim, setting%num_filter, SY_desc, SY)
      call pdgemm('No', 'No', dim, setting%num_filter, dim, 1d0, &
           S, 1, 1, S_desc, &
           Y_filtered, 1, 1, Y_filtered_desc, &
           0d0, &
           SY, 1, 1, SY_desc)
    end if

    if (setting%is_reduction_mode) then
      call terminate('read_next_input_step_with_basis_replace: reduction mode is not implemented in this version', 1)
    end if

    if (to_use_precomputed_eigenpairs) then
      if (size(eigenvalues, 1) /= dim) then
        call terminate('wrong size of eigenvalues', 1)
      end if
      if (desc_eigenvectors(rows_) /= dim .or. desc_eigenvectors(cols_) /= dim) then
        call terminate('wrong size of eigenvectors', 1)
      end if
      end_filter = setting%fst_filter + setting%num_filter - 1
      dv_eigenvalues(1 : setting%num_filter) = eigenvalues(setting%fst_filter : end_filter)
      call pdgemr2d(dim, setting%num_filter, &
           eigenvectors, 1, setting%fst_filter, desc_eigenvectors, &
           Y_filtered, 1, 1, Y_filtered_desc, &
           desc_eigenvectors(context_))
    else
      call set_eigenpairs(dim, setting, proc, filter_group_id, structure, H_sparse, S_sparse, Y_desc, Y, &
           dv_eigenvalues, Y_filtered_desc, Y_filtered, filter_group_indices)
    end if
    call add_timer_event('read_next_input_step_with_basis_replace', 'set_eigenpairs', wtime)

    if (trim(setting%re_initialize_method) == 'minimize_lcao_error_matrix_suppress') then
      call pdgemm('Trans', 'No', setting%num_filter, setting%num_filter, dim, 1d0, &
           Y_filtered, 1, 1, Y_filtered_desc, &
           SY, 1, 1, SY_desc, &
           0d0, &
           YSY_filtered, 1, 1, YSY_filtered_desc)
      deallocate(S, SY)
    end if

    allocate(eigenstate_charges(size(group_id, 2), setting%num_filter))
    call get_eigenstate_charges_on_groups(Y_filtered, Y_filtered_desc, &
         structure, group_id, eigenstate_charges, eigenstate_ipratios)
    deallocate(eigenstate_charges)
    call add_timer_event('read_next_input_step_with_basis_replace', 'get_eigenstate_charges_on_groups', wtime)

    ! group filter mode is not implemented now
    !call set_local_eigenvectors(setting, proc, Y_filtered_desc, Y_filtered, filter_group_indices, Y_local)
    !call add_timer_event('read_next_input_step_with_basis_replace', 'set_local_eigenvectors', wtime)
    !
    !call set_H1_base(setting, proc, filter_group_indices, Y_local, H_sparse, H1_base, H1_desc)
    !call add_timer_event('read_next_input_step_with_basis_replace', 'set_H1_base', wtime)

    !call get_msd_of_eigenstates(proc, dim, num_atoms, atom_indices, atom_coordinates, &
    !     S, S_desc, Y_filtered, Y_filtered_desc, &
    !     full_vecs, full_vecs_desc, filtered_vecs, filtered_vecs_desc)
    !call get_msd_of_eigenstates(structure, S_sparse, Y_filtered, Y_filtered_desc, means_all, msds_all)
    call add_timer_event('read_next_input_step_with_basis_replace', 'get_msd_of_eigenstates (skipped)', wtime)

    !call get_ipratio_of_eigenstates(Y_filtered, Y_filtered_desc, ipratios)
    call add_timer_event('read_next_input_step_with_basis_replace', 'get_ipratio_of_eigenstates (skipped)', wtime)
    ! Should output information of eigenstates to JSON output.

    ! Time step was incremented after the last calculation of alpha,
    ! so the time for conversion between LCAO coefficient and eigenstate expansion
    ! is t - setting%delta_t, not t.
    call re_initialize_state(setting, proc, dim, t - setting%delta_t, structure, charge_factor, &
         H_sparse, S_sparse, &  !full_vecs, full_vecs_desc, filtered_vecs, filtered_vecs_desc, &
         Y_filtered, Y_filtered_desc, &
         YSY_filtered, YSY_filtered_desc, &
         dv_eigenvalues_prev, dv_eigenvalues, filter_group_indices, Y_local, &
         H1_base, H1, H1_desc, dv_psi, dv_alpha, dv_psi_reconcile, dv_alpha_reconcile, &
         dv_charge_on_basis, dv_charge_on_atoms, &
         charge_moment, energies, errors)
    call add_timer_event('read_next_input_step_with_basis_replace', 're_initialize_from_lcao_coef', wtime)
  end subroutine read_next_input_step_with_basis_replace


  subroutine read_next_input_step_matrix(setting, &
       S_multistep_sparse, &
       filter_group_indices)
    integer, intent(in) :: filter_group_indices(:, :)
    type(wp_setting_t), intent(in) :: setting
    type(sparse_mat), intent(inout) :: S_multistep_sparse

    call clear_offdiag_blocks_of_overlap(setting, filter_group_indices, S_multistep_sparse)
    if (setting%is_reduction_mode) then
      call terminate('read_next_input_step_matrix: reduction mode is not implemented in this version', 1)
    end if
  end subroutine read_next_input_step_matrix


  subroutine make_matrix_step_forward(setting, proc, state)
    type(wp_setting_t), intent(in) :: setting
    type(wp_process_t), intent(in) :: proc
    type(wp_state_t), intent(inout) :: state
    ! The commented out parameters below are in 'state'.
    !type(wp_structure_t), intent(in) :: structure
    !integer, intent(in) :: input_step, filter_group_indices(:, :)
    !type(wp_charge_factor_t), intent(in) :: charge_factor
    !type(sparse_mat), intent(in) :: H_sparse, S_sparse
    !integer, intent(in) :: Y_filtered_desc(desc_size), H1_desc(desc_size), A_desc(desc_size)
    !real(8), intent(in) :: t, dv_charge_on_atoms(:), dv_eigenvalues(:)
    !complex(kind(0d0)), intent(inout) :: A(:, :)
    !real(8), intent(inout) :: H1(:, :), H1_base(:, :), H1_multistep(:, :)
    !real(8), intent(in) :: Y_filtered(:, :)
    !type(wp_local_matrix_t), intent(in) :: Y_local(:)
    !complex(kind(0d0)) :: dv_alpha(:), dv_alpha_next(:)

    real(8) :: multistep_mix_ratio, wtime

    wtime = mpi_wtime()

    if (trim(setting%h1_type) == 'zero' .and. trim(setting%filter_mode) /= 'group') then  ! Skip time evolution calculation.
      state%dv_alpha_next(:) = state%dv_alpha(:)
      call add_timer_event('make_matrix_step_forward', 'step_forward_linear', wtime)
    else
      ! H_multistep1 is not referenced.
      call make_H1(proc, trim(setting%h1_type), state%structure, &
           state%S_sparse, state%Y_filtered, state%Y_filtered_desc, .false., setting%is_restart_mode, &
           trim(setting%filter_mode) == 'group', state%filter_group_indices, state%Y_local, &
           state%t, setting%temperature, setting%delta_t, setting%perturb_interval, &
           state%dv_charge_on_atoms, state%charge_factor, &
           state%H1, state%H1_desc)
      call add_timer_event('make_matrix_step_forward', 'make_matrix_H1_not_multistep', wtime)

      if (.not. setting%to_replace_basis) then
        state%H1(:, :) = state%H1(:, :) + state%H1_multistep(:, :)  ! Sum of distributed matrices.
      end if

      if (trim(setting%filter_mode) == 'group') then
        state%H1(:, :) = state%H1(:, :) + state%H1_base(:, :)  ! Sum of distributed matrices.
      end if

      call make_A(state%H1, state%H1_desc, state%dv_eigenvalues, state%t, &
           setting%amplitude_print_threshold, setting%amplitude_print_interval, &
           setting%delta_t, setting%fst_filter, &
           state%A, state%A_desc)
      call add_timer_event('make_matrix_step_forward', 'make_matrix_A', wtime)

      ! Note that step_forward destroys A.
      call step_forward(setting%time_evolution_mode, state%A, state%A_desc, setting%delta_t, &
           state%dv_alpha, state%dv_alpha_next)
      call add_timer_event('make_matrix_step_forward', 'step_forward', wtime)
    end if
  end subroutine make_matrix_step_forward


  subroutine step_forward_post_process(setting, state)
    type(wp_setting_t), intent(in) :: setting
    type(wp_state_t), intent(inout) :: state
    ! The commented out parameters below are in 'state'.
    !integer, intent(in) :: dim
    !type(sparse_mat), intent(in) :: H_sparse, S_sparse
    !type(wp_structure_t), intent(in) :: structure
    !type(wp_charge_factor_t), intent(in) :: charge_factor
    !integer, intent(in) :: Y_filtered_desc(desc_size), H1_desc(desc_size)
    !complex(kind(0d0)), intent(in) :: dv_alpha_next(:)
    !complex(kind(0d0)), intent(out) :: dv_alpha(:), dv_psi(dim)
    !real(8), intent(in) :: t, Y_filtered(:, :), dv_eigenvalues(:), H1(:, :)
    !type(wp_charge_moment_t), intent(out) :: charge_moment
    !type(wp_energy_t), intent(out) :: energies

    integer :: num_filter
    real(8) :: wtime
    real(8) :: dv_charge_on_basis(state%dim), dv_charge_on_atoms(state%structure%num_atoms)
    complex(kind(0d0)) :: dv_evcoef(state%Y_filtered_desc(cols_)), energy_tmp

    wtime = mpi_wtime()

    num_filter = state%Y_filtered_desc(cols_)

    call alpha_to_lcao_coef(state%Y_filtered, state%Y_filtered_desc, state%dv_eigenvalues, &
         state%t, state%dv_alpha_next, state%dv_psi)
    call add_timer_event('step_forward_post_process', 'alpha_to_lcao_coef', wtime)

    call get_mulliken_charges_on_basis(state%dim, state%S_sparse, state%dv_psi, dv_charge_on_basis)
    call add_timer_event('step_forward_post_process', 'get_mulliken_charges_on_basis', wtime)

    call get_mulliken_charges_on_atoms(state%dim, state%structure, state%S_sparse, &
         state%dv_psi, dv_charge_on_atoms)
    call add_timer_event('step_forward_post_process', 'get_mulliken_charges_on_atoms', wtime)

    call get_mulliken_charge_coordinate_moments(state%structure, dv_charge_on_atoms, state%charge_moment)
    call add_timer_event('step_forward_post_process', 'get_mulliken_charge_coordinate_moments', wtime)

    call get_A_sparse_inner_product(state%dim, state%H_sparse, state%dv_psi, state%dv_psi, energy_tmp)
    state%energies%tightbinding = truncate_imag(energy_tmp)
    call alpha_to_eigenvector_coef(num_filter, state%dv_eigenvalues, state%t, state%dv_alpha_next, dv_evcoef)

    if (trim(setting%h1_type) == 'charge_overlap') then
      call get_charge_overlap_energy(state%structure, state%charge_factor, &
           state%dv_charge_on_atoms, state%energies%nonlinear)
    else
      call get_A_inner_product(num_filter, state%H1, state%H1_desc, dv_evcoef, dv_evcoef, energy_tmp)
      state%energies%nonlinear = truncate_imag(energy_tmp)
      if (trim(setting%h1_type) == 'charge') then
        state%energies%nonlinear = state%energies%nonlinear / 2d0
      end if
    end if
    state%energies%total = state%energies%tightbinding + state%energies%nonlinear
    call add_timer_event('step_forward_post_process', 'compute_energy', wtime)

    state%dv_alpha(:) = state%dv_alpha_next(:)
    call add_timer_event('step_forward_post_process', 'move_alpha_between_time_steps', wtime)
  end subroutine step_forward_post_process


  subroutine get_simulation_ranges(states, min_time, max_time, min_step_num, max_step_num, &
       min_input_step, max_input_step)
    type(fson_value), pointer, intent(in) :: states
    real(8), intent(out) :: min_time, max_time
    integer, intent(out) :: min_step_num, max_step_num, min_input_step, max_input_step
    type(fson_value), pointer :: state, state_elem

    min_time = huge(min_time)
    max_time = -huge(max_time)
    min_step_num = huge(min_step_num)
    max_step_num = -huge(max_step_num)
    min_input_step = huge(min_input_step)
    max_input_step = -huge(max_input_step)

    state => states%children
    do while (associated(state))
      state_elem => fson_value_get(state, 'time')
      min_time = min(min_time, state_elem%value_real)
      max_time = max(max_time, state_elem%value_real)
      state_elem => fson_value_get(state, 'step_num')
      min_step_num = min(min_step_num, state_elem%value_integer)
      max_step_num = max(max_step_num, state_elem%value_integer)
      state_elem => fson_value_get(state, 'input_step')
      min_input_step = min(min_input_step, state_elem%value_integer)
      max_input_step = max(max_input_step, state_elem%value_integer)
      state => state%next
    end do
  end subroutine get_simulation_ranges


  subroutine save_state(setting, is_after_matrix_replace, state)
    type(wp_setting_t), intent(in) :: setting
    logical, intent(in) :: is_after_matrix_replace
    type(wp_state_t), intent(inout) :: state
    ! The commented out parameters below are in 'state'.
    !integer, intent(in) :: dim, i, group_id(:, :), Y_filtered_desc(desc_size)
    !type(wp_structure_t), intent(in) :: structure
    !complex(kind(0d0)), intent(in) :: dv_psi(dim), dv_alpha(structure%num_atoms)
    !type(wp_energy_t), intent(in) :: energies
    !type(wp_charge_moment_t), intent(in) :: charge_moment
    !real(8), intent(in) :: dv_atom_perturb(:), dv_atom_speed(:), dv_charge_on_basis(:), dv_charge_on_atoms(:)
    !real(8), intent(in) :: t, t_last_replace, Y_filtered(:, :)
    !integer, intent(inout) :: total_state_count, input_step
    !type(fson_value), pointer, intent(inout) :: split_files_metadata, states, structures

    real(8) :: wtime
    integer :: master_prow, master_pcol, states_count, input_step_backup
    real(8), allocatable :: atom_coordinates_backup(:, :)
    real(8) :: t_backup
    type(fson_value), pointer :: last_structure

    wtime = mpi_wtime()

    call add_timer_event('save_state', 'gather_matrix_to_save_state', wtime)

    if (check_master()) then
      call add_state_json(state%dim, setting%num_filter, state%structure, state%i, state%t, state%input_step, &
           state%energies, state%dv_alpha, state%dv_psi, &
           state%dv_charge_on_basis, state%dv_charge_on_atoms, state%charge_moment, &
           setting%h1_type, state%dv_atom_speed, state%dv_atom_perturb, &
           is_after_matrix_replace, state%states)
      state%total_state_count = state%total_state_count + 1
      if (setting%is_output_split) then
        states_count = fson_value_count(state%states)
        ! 'i + setting%output_interval' in the next condition expression is
        ! the next step that satisfies 'mod(i, setting%output_interval) == 0'.
        if (states_count >= setting%num_steps_per_output_split .or. &
             setting%delta_t * (state%i + setting%output_interval) >= setting%limit_t) then
          call output_split_states(setting, state%total_state_count, state%states, &
               state%structures, state%split_files_metadata)
          ! Reset json array of states.
          ! Back up the last structure.
          allocate(atom_coordinates_backup(3, state%structure%num_atoms))
          last_structure => fson_value_get(state%structures, fson_value_count(state%structures))
          call fson_path_get(last_structure, 'time', t_backup)
          call fson_path_get(last_structure, 'input_step', input_step_backup)
          call fson_path_get(last_structure, 'coordinates_x', atom_coordinates_backup(1, :))
          call fson_path_get(last_structure, 'coordinates_y', atom_coordinates_backup(2, :))
          call fson_path_get(last_structure, 'coordinates_z', atom_coordinates_backup(3, :))
          ! Destroy jsons.
          call fson_destroy(state%states)
          call fson_destroy(state%structures)
          state%states => fson_value_create()
          state%structures => fson_value_create()
          call fson_set_name('states', state%states)
          call fson_set_name('structures', state%structures)
          state%states%value_type = TYPE_ARRAY
          state%structures%value_type = TYPE_ARRAY
          ! Write the last atomic structure to make the split file independent from others.
          call add_structure_json(t_backup, input_step_backup, state)
        end if
      end if
    end if
    call add_timer_event('save_state', 'add_and_print_state', wtime)
  end subroutine save_state


  subroutine output_split_states(setting, total_state_count, states, structures, split_files_metadata)
    type(wp_setting_t), intent(in) :: setting
    integer, intent(in) :: total_state_count
    type(fson_value), pointer, intent(in) :: states, structures
    type(fson_value), pointer, intent(inout) :: split_files_metadata

    integer, parameter :: iunit_split = 12, iunit_split_binary = 18
    real(8) :: min_time, max_time
    integer :: min_step_num, max_step_num, min_input_step, max_input_step
    type(fson_value), pointer :: metadata, metadata_elem, whole
    real(8) :: wtime
    integer :: states_count, binary_num_last_value
    character(len=1024) :: filename, binary_filename, binary_filename_basename  ! Output splitting.
    integer :: basename_start_index

    wtime = mpi_wtime()

    states_count = fson_value_count(states)
    filename = add_numbers_to_filename(setting%output_filename, &
         total_state_count - states_count + 1, total_state_count)
    call get_simulation_ranges(states, min_time, max_time, min_step_num, max_step_num, &
         min_input_step, max_input_step)
    metadata => fson_value_create()
    metadata%value_type = TYPE_OBJECt
    ! metadata element: filename.
    metadata_elem => fson_value_create()
    metadata_elem%value_type = TYPE_OBJECT
    call fson_set_name('filename', metadata_elem)
    call fson_set_as_string(trim(remove_directory_from_filename(filename)), metadata_elem)
    call fson_value_add(metadata, metadata_elem)
    ! metadata element min_time:
    metadata_elem => fson_value_create()
    metadata_elem%value_type = TYPE_REAL
    call fson_set_name('min_time', metadata_elem)
    metadata_elem%value_real = min_time
    call fson_value_add(metadata, metadata_elem)
    ! metadata element max_time:
    metadata_elem => fson_value_create()
    metadata_elem%value_type = TYPE_REAL
    call fson_set_name('max_time', metadata_elem)
    metadata_elem%value_real = max_time
    call fson_value_add(metadata, metadata_elem)
    ! metadata element min_step_num:
    metadata_elem => fson_value_create()
    metadata_elem%value_type = TYPE_INTEGER
    call fson_set_name('min_step_num', metadata_elem)
    metadata_elem%value_integer = min_step_num
    call fson_value_add(metadata, metadata_elem)
    ! metadata element max_step_num:
    metadata_elem => fson_value_create()
    metadata_elem%value_type = TYPE_INTEGER
    call fson_set_name('max_step_num', metadata_elem)
    metadata_elem%value_integer = max_step_num
    call fson_value_add(metadata, metadata_elem)
    ! metadata element min_input_step:
    metadata_elem => fson_value_create()
    metadata_elem%value_type = TYPE_INTEGER
    call fson_set_name('min_input_step', metadata_elem)
    metadata_elem%value_integer = min_input_step
    call fson_value_add(metadata, metadata_elem)
    ! metadata element max_input_step:
    metadata_elem => fson_value_create()
    metadata_elem%value_type = TYPE_INTEGER
    call fson_set_name('max_input_step', metadata_elem)
    metadata_elem%value_integer = max_input_step
    call fson_value_add(metadata, metadata_elem)
    ! Add metadata of current split file to the accumulation array.
    call fson_value_add(split_files_metadata, metadata)

    whole => fson_value_create()
    whole%value_type = TYPE_OBJECT
    call fson_value_add(whole, states)
    call fson_value_add(whole, structures)

    call add_timer_event('output_split_states', 'prepare_split_file_metadata', wtime)

    open(iunit_split, file=trim(filename))
    if (setting%is_binary_output_mode) then
      binary_filename = trim(filename) // '.dat'
      basename_start_index = index(binary_filename, '/', back=.true.) + 1
      binary_filename_basename = trim(binary_filename(basename_start_index : ))
      open(iunit_split_binary, file=trim(binary_filename), form='unformatted', access='stream')
      binary_num_last_value = 0
      call fson_print(iunit_split, whole, .false., .true., 0, &
           iunit_split_binary, trim(binary_filename_basename), binary_num_last_value)
      close(iunit_split_binary)
    else
      call fson_print(iunit_split, whole)
    end if
    close(iunit_split)

    call add_timer_event('output_split_states', 'fson_print', wtime)
  end subroutine output_split_states


  subroutine output_fson_and_destroy(setting, output, split_files_metadata, states, structures, wtime_total)
    type(wp_setting_t), intent(in) :: setting
    type(fson_value), pointer, intent(inout) :: output, split_files_metadata, states, structures
    real(8), intent(inout) :: wtime_total

    integer :: iunit_master
    real(8) :: wtime

    wtime = mpi_wtime()

    if (check_master()) then
      if (setting%is_output_split) then
        call fson_value_add(output, split_files_metadata)
      else
        call fson_value_add(output, states)
        call fson_value_add(output, structures)
      end if

      call add_timer_event('main', 'write_states_to_fson', wtime)
      call add_timer_event('main', 'total', wtime_total)

      if (trim(setting%output_filename) /= '-') then
        iunit_master = 11
        open(iunit_master, file=setting%output_filename)
      else
        iunit_master = 6
      end if
      call fson_events_add(output)
      call fson_print(iunit_master, output)
      if (trim(setting%output_filename) /= '-') then
        close(iunit_master)
      end if
    end if

    if (check_master()) then
      write (0, '(A, F16.6, A)') ' [Event', mpi_wtime() - g_wp_mpi_wtime_init, &
           '] main loop end'
    end if

    call fson_destroy(output)
  end subroutine output_fson_and_destroy
end module wp_main_aux_m