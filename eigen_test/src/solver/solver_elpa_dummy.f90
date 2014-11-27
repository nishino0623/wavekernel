module solver_elpa
  use distribute_matrix, only : process
  use descriptor_parameters
  use eigenpairs_types, only : eigenpairs_types_union
  use matrix_io, only : sparse_mat
  use processes, only : check_master, terminate
  use time, only : get_wall_clock_base_count, get_wall_clock_time

  implicit none
  private
  public :: solve_with_general_elpa_scalapack, solve_with_general_elpa1, solve_with_general_elpa2

contains

  subroutine solve_with_general_elpa_scalapack(n,matrix_A, eigenpairs, matrix_B)
    type(sparse_mat), intent(in) :: matrix_A
    type(sparse_mat), intent(in), optional :: matrix_B
    type(eigenpairs_types_union), intent(out) :: eigenpairs

    call terminate('solve_elpa: ELPA is not supported in this build', 1)
  end subroutine solve_with_general_elpa_scalapack

  subroutine solve_with_general_elpa1(n,matrix_A, eigenpairs, matrix_B)
    type(sparse_mat), intent(in) :: matrix_A
    type(sparse_mat), intent(in), optional :: matrix_B
    type(eigenpairs_types_union), intent(out) :: eigenpairs

    call terminate('solve_elpa: ELPA is not supported in this build', 1)
  end subroutine solve_with_general_elpa1

  subroutine solve_with_general_elpa1(n,matrix_A, eigenpairs, matrix_B)
    type(sparse_mat), intent(in) :: matrix_A
    type(sparse_mat), intent(in), optional :: matrix_B
    type(eigenpairs_types_union), intent(out) :: eigenpairs

    call terminate('solve_elpa: ELPA is not supported in this build', 1)
  end subroutine solve_with_general_elpa1


  subroutine solve_with_general_elpa2
    type(sparse_mat), intent(in) :: matrix_A
    type(sparse_mat), intent(in), optional :: matrix_B
    type(eigenpairs_types_union), intent(out) :: eigenpairs

    call terminate('solve_elpa: ELPA is not supported in this build', 1)
  end subroutine solve_with_general_elpa2
end module solver_elpa
