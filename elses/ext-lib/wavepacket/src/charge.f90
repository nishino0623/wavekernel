module wp_charge_m
  use mpi
  use wp_atom_m
  use wp_descriptor_parameters_m
  use wp_event_logger_m
  use wp_linear_algebra_m
  use wp_matrix_io_m
  use wp_processes_m
  use wp_global_variables_m
  use wp_util_m
  implicit none

  private
  external :: blacs_pnum
  integer :: blacs_pnum

  public :: wp_charge_moment_t, wp_charge_factor_t, &
       get_mulliken_charges_on_basis, get_mulliken_charges_on_atoms, &
       get_eigenstate_charges_on_groups, get_charge_overlap_energy, &
       get_mulliken_charge_coordinate_moments, get_msd_of_eigenstates, get_ipratio_of_eigenstates, get_charge_factor

  type wp_charge_moment_t
    real(8) :: means(3)
    real(8) :: msds(4)
  end type wp_charge_moment_t

  type wp_charge_factor_t
    real(8) :: charge_factor_common, charge_factor_H, charge_factor_C
  end type wp_charge_factor_t

contains

  ! Complexity: O(m^2).
  ! full_work <- S psi
  ! charge(col_charges_on_basis)_k = real(conjg(psi_k) * full_work_k)
  subroutine get_mulliken_charges_on_basis(dim, S_sparse, dv_psi, dv_charge_on_basis)
    integer, intent(in) :: dim
    type(sparse_mat), intent(in) :: S_sparse
    complex(kind(0d0)), intent(in) :: dv_psi(dim)
    real(8), intent(out) :: dv_charge_on_basis(dim)

    integer :: k
    complex(kind(0d0)) :: dv_work(dim)
    real(8) :: charge_k, sum_mulliken_charges
    real(8) :: wtime_start, wtime_end

    wtime_start = mpi_wtime()

    dv_work(:) = kZero
    call matvec_sd_z('No', S_sparse, kOne, dv_psi, kZero, dv_work)

    wtime_end = mpi_wtime()
    call add_event('get_mulliken_charges_on_basis:matvec_sd_z', wtime_end - wtime_start)
    wtime_start = wtime_end

    sum_mulliken_charges = 0d0  ! Must be 1 after summation. Valid only in master.
    do k = 1, dim
      charge_k = dble(dconjg(dv_psi(k)) * dv_work(k))
      dv_charge_on_basis(k) = charge_k
      sum_mulliken_charges = sum_mulliken_charges + charge_k
    end do

    wtime_end = mpi_wtime()
    call add_event('get_mulliken_charges_on_basis:sum_charges', wtime_end - wtime_start)

    if (check_master()) then
      if (abs(sum_mulliken_charges - 1d0) > charge_sum_error_tol) then
        write(0, *) 'Warn: sum of mulliken charges on LCAO basis is distant from one'
        write(0, '(A, E26.16e3)') ' sum_mulliken_charges: ', sum_mulliken_charges
      end if
    end if
  end subroutine get_mulliken_charges_on_basis


  ! Complexity: O(m^2).
  subroutine get_mulliken_charges_on_atoms(dim, structure, S_sparse, dv_psi, dv_charge_on_atoms)
    integer, intent(in) :: dim
    type(wp_structure_t) :: structure
    type(sparse_mat), intent(in) :: S_sparse
    complex(kind(0d0)), intent(in) :: dv_psi(dim)
    real(8), intent(out) :: dv_charge_on_atoms(structure%num_atoms)

    integer :: a, atom_index_start, atom_index_end, k
    complex(kind(0d0)) :: dv_work(dim)
    real(8) :: wtime_start, wtime_end, sum_mulliken_charges, charge_a

    wtime_start = mpi_wtime()

    dv_work(:) = kZero
    call matvec_sd_z('No', S_sparse, kOne, dv_psi, kZero, dv_work)

    wtime_end = mpi_wtime()
    call add_event('get_mulliken_charges_on_atoms:matvec_sd_z', wtime_end - wtime_start)
    wtime_start = wtime_end

    sum_mulliken_charges = 0d0  ! Must be 1 after summation.
    do a = 1, structure%num_atoms
      charge_a = 0d0
      atom_index_start = structure%atom_indices(a)
      atom_index_end = structure%atom_indices(a + 1) - 1
      do k = atom_index_start, atom_index_end
        charge_a = charge_a + dble(dconjg(dv_psi(k)) * dv_work(k))
        call check_nan_scalar(charge_a)
      end do
      dv_charge_on_atoms(a) = charge_a
      sum_mulliken_charges = sum_mulliken_charges + charge_a
    end do

    wtime_end = mpi_wtime()
    call add_event('get_mulliken_charges_on_atoms:sum_charges', wtime_end - wtime_start)

    if (check_master()) then
      if (abs(sum_mulliken_charges - 1d0) > charge_sum_error_tol) then
        write(0, *) 'Warn: sum of mulliken charges on atoms is distant from one'
        write(0, '(A, E26.16e3)') ' sum_mulliken_charges: ', sum_mulliken_charges
      end if
    end if
  end subroutine get_mulliken_charges_on_atoms


  ! charges(group, k): \sum_{i \in (atom \in group)} y_{i, k}^2 / \sum_{i} y_{i, k}^2
  ! ipratios(k): \sum_{g} charges(g, k)^2 (ipratio for sqrt{\sum_{i \in (atom \in group(g))} y_{i, k}^2})
  subroutine get_eigenstate_charges_on_groups(Y_filtered, Y_filtered_desc, structure, group_id, charges, ipratios)
    real(8), intent(in) :: Y_filtered(:, :)
    integer, intent(in) :: Y_filtered_desc(desc_size)
    type(wp_structure_t), intent(in) :: structure
    integer, intent(in) :: group_id(:, :)
    real(8), intent(out) :: charges(size(group_id, 2), Y_filtered_desc(cols_))
    real(8), intent(out) :: ipratios(Y_filtered_desc(cols_))

    integer :: nprow, npcol, myrow, mycol, myrank
    integer :: lrindx, lcindx, rsrc, csrc
    integer :: k, g, ai, a, atom_index_start, atom_index_end, i, ierr
    real(8) :: charges_buf(size(group_id, 2), Y_filtered_desc(cols_)), charges_sum
    real(8) :: ipratios_buf(Y_filtered_desc(cols_))
    integer :: indxl2g, blacs_pnum  ! Function.

    call blacs_gridinfo(Y_filtered_desc(context_), nprow, npcol, myrow, mycol)
    charges_buf(:, :) = 0d0
    do k = 1, Y_filtered_desc(cols_)
      do g = 1, size(group_id, 2)
        do ai = 1, group_id(1, g)
          a = group_id(ai + 1, g)
          atom_index_start = structure%atom_indices(a)
          atom_index_end = structure%atom_indices(a + 1) - 1
          do i = atom_index_start, atom_index_end
            call infog2l(i, k, Y_filtered_desc, nprow, npcol, myrow, mycol, lrindx, lcindx, rsrc, csrc)
            if (myrow == rsrc .and. mycol == csrc) then
              charges_buf(g, k) = charges_buf(g, k) + Y_filtered(lrindx, lcindx) ** 2d0
            end if
          end do
        end do
      end do
    end do
    charges(:, :) = 0d0
    call mpi_allreduce(charges_buf, charges, size(group_id, 2) * Y_filtered_desc(cols_), &
         mpi_double_precision, mpi_sum, mpi_comm_world, ierr)
    charges_buf(:, :) = 0d0
    ipratios_buf(:) = 0d0
    call mpi_comm_rank(mpi_comm_world, myrank, ierr)
    do k = 1, Y_filtered_desc(cols_)
      if (myrank == mod(k, nprow * npcol)) then
        charges_sum = sum(charges(:, k))
        charges_buf(:, k) = charges(:, k) / charges_sum
        ipratios_buf(k) = sum(charges_buf(:, k) ** 2d0)
      end if
    end do
    charges(:, :) = 0d0
    ipratios(:) = 0d0
    call mpi_allreduce(charges_buf, charges, size(group_id, 2) * Y_filtered_desc(cols_), &
         mpi_double_precision, mpi_sum, mpi_comm_world, ierr)
    call mpi_allreduce(ipratios_buf, ipratios, Y_filtered_desc(cols_), &
         mpi_double_precision, mpi_sum, mpi_comm_world, ierr)
  end subroutine get_eigenstate_charges_on_groups


  ! Definition of energy from the nonlinear term when h1_type is "charge_overlap".
  ! Called after calling get_mulliken_charges_on_atoms.
  subroutine get_charge_overlap_energy(structure, charge_factor, dv_charge_on_atoms, energy)
    type(wp_structure_t), intent(in) :: structure
    type(wp_charge_factor_t), intent(in) :: charge_factor
    real(8), intent(in) :: dv_charge_on_atoms(structure%num_atoms)
    real(8), intent(out) :: energy

    integer :: i
    real(8) :: charge, factor, sum_charge_squared

    sum_charge_squared = 0d0
    do i = 1, structure%num_atoms
      charge = dv_charge_on_atoms(i)
      factor = get_charge_factor(i, structure, charge_factor)
      sum_charge_squared = sum_charge_squared + factor * (charge ** 2d0)
    end do
    energy = - 0.5d0 * sum_charge_squared
  end subroutine get_charge_overlap_energy


  subroutine get_mulliken_charge_coordinate_moments(structure, dv_charge_on_atoms, charge_moment)
    type(wp_structure_t), intent(in) :: structure
    real(8), intent(in) :: dv_charge_on_atoms(structure%num_atoms)
    type(wp_charge_moment_t), intent(out) :: charge_moment

    real(8) :: normalizer, ratio
    integer :: i, j

    normalizer = sum(dv_charge_on_atoms(:))
    charge_moment%means(:) = 0d0
    charge_moment%msds(:) = 0d0
    do i = 1, structure%num_atoms
      ratio = dv_charge_on_atoms(i) / normalizer
      do j = 1, 3
        charge_moment%means(j) = charge_moment%means(j) + structure%atom_coordinates(j, i) * ratio
        charge_moment%msds(j) = charge_moment%msds(j) + (structure%atom_coordinates(j, i) ** 2d0) * ratio
      end do
    end do
    do j = 1, 3
      charge_moment%msds(j) = charge_moment%msds(j) - charge_moment%means(j) ** 2d0
    end do
    charge_moment%msds(4) = charge_moment%msds(1) + charge_moment%msds(2) + charge_moment%msds(3)
  end subroutine get_mulliken_charge_coordinate_moments


  subroutine get_msd_of_eigenstates(structure, S_sparse, Y_filtered, Y_filtered_desc, means_all, msds_all)
    type(sparse_mat), intent(in) :: S_sparse
    integer, intent(in) :: Y_filtered_desc(desc_size)
    type(wp_structure_t), intent(in) :: structure
    real(8), intent(in) :: Y_filtered(:, :)
    real(8), intent(out) :: means_all(3, Y_filtered_desc(cols_)), msds_all(4, Y_filtered_desc(cols_))

    real(8) :: dv_psi_local(Y_filtered_desc(rows_)), dv_psi(Y_filtered_desc(rows_))
    real(8) :: dv_charge_on_atoms(structure%num_atoms)
    integer :: dim, num_filter, i, j, print_count, ierr
    type(wp_charge_moment_t) ::charge_moment

    dim = Y_filtered_desc(rows_)
    num_filter = Y_filtered_desc(cols_)
    print_count = 1
    do i = 1, num_filter
      if (i > num_filter / 10 * print_count .and. &
           check_master()) then
        write (0, '(A, F16.6, A, I0)') ' [Event', mpi_wtime() - g_wp_mpi_wtime_init, &
             '] calculating MSD of eigenstate ', i
        print_count = print_count + 1
      end if
      dv_psi_local(:) = 0d0
      do j = 1, dim
        call pdelget('Self', ' ', dv_psi_local(j), Y_filtered, j, i, Y_filtered_desc)
      end do
      call mpi_allreduce(dv_psi_local, dv_psi, dim, mpi_real8, mpi_sum, mpi_comm_world, ierr)
      call get_mulliken_charges_on_atoms(dim, structure, S_sparse, dcmplx(dv_psi), dv_charge_on_atoms)
      call get_mulliken_charge_coordinate_moments(structure, dv_charge_on_atoms, charge_moment)
      means_all(1 : 3, i) = charge_moment%means(1 : 3)
      msds_all(1 : 4, i) = charge_moment%msds(1 : 4)
    end do
  end subroutine get_msd_of_eigenstates


  subroutine get_ipratio_of_eigenstates(Y_filtered, Y_filtered_desc, ipratios)
    integer, intent(in) :: Y_filtered_desc(desc_size)
    real(8), intent(in) :: Y_filtered(:, :)
    real(8), intent(out) :: ipratios(Y_filtered_desc(cols_))

    integer :: dim, num_filter, i, j, n_procs_row, n_procs_col, my_proc_row, my_proc_col
    real(8) :: sum_power4(Y_filtered_desc(cols_)), sum_power2(Y_filtered_desc(cols_))
    real(8) :: elem
    integer :: indxg2p

    dim = Y_filtered_desc(rows_)
    num_filter = Y_filtered_desc(cols_)

    call blacs_gridinfo(Y_filtered_desc(context_), n_procs_row, n_procs_col, my_proc_row, my_proc_col)
    sum_power4(:) = 0d0
    sum_power2(:) = 0d0
    do j = 1, num_filter
      if (indxg2p(j, Y_filtered_desc(block_col_), 0, 0, n_procs_col) == my_proc_col) then
        do i = 1, dim
          if (indxg2p(i, Y_filtered_desc(block_row_), 0, 0, n_procs_row) == my_proc_row) then
            call pdelget('', '', elem, Y_filtered, i, j, Y_filtered_desc)
            sum_power4(j) = sum_power4(j) + elem ** 4d0
            sum_power2(j) = sum_power2(j) + elem ** 2d0
          end if
        end do
      end if
    end do
    call dgsum2d(Y_filtered_desc(context_), 'All', ' ', 1, num_filter, sum_power4, 1, -1, -1)
    call dgsum2d(Y_filtered_desc(context_), 'All', ' ', 1, num_filter, sum_power2, 1, -1, -1)

    do j = 1, num_filter
      ipratios(j) = sum_power4(j) / (sum_power2(j) ** 2d0)
    end do
  end subroutine get_ipratio_of_eigenstates


  real(8) function get_charge_factor(atom_i, structure, charge_factor)
    integer, intent(in) :: atom_i
    type(wp_structure_t), intent(in) :: structure
    type(wp_charge_factor_t), intent(in) :: charge_factor

    if (structure%atom_elements(atom_i) == 'H' .and. charge_factor%charge_factor_H >= 0d0) then
      get_charge_factor = charge_factor%charge_factor_H
    else if (structure%atom_elements(atom_i) == 'C' .and. charge_factor%charge_factor_C >= 0d0) then
      get_charge_factor = charge_factor%charge_factor_C
    else
      get_charge_factor = charge_factor%charge_factor_common
    end if
  end function get_charge_factor
end module wp_charge_m
