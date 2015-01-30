!================================================================
! ELSES version 0.05
! Copyright (C) ELSES. 2007-2015 all rights reserved
!================================================================
!zzz  @@@@ elses-lib-get-arg.f90 @@@@@
!zzz  @@@@@ 2008/12/06 @@@@@
!ccc2007cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!1229: T.Hoshi; Prepared. (v.0.0.0a-2007_12_29_hoshi)
!       Copied from elses-xml-02.f
!ccc2008cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!1206: T.Hoshi; Copied from ELSES-GENO version (NT08G-129)
!cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!
!! Copyright (C) ELSES. 2007-2015 all rights reserved
module M_options
  use M_config
contains
  subroutine elses_process_options
    implicit none
    integer :: i
    character(len=256) :: argv
!    
    call option_default( config%option ) 
!    
    do i=1, command_argument_count()
       call get_command_argument(i,argv)
!       
       if( argv(1:1) == "-" ) then
          select case(argv(2:))
          case("band":"band@")
             config%option%functionality=argv(2:)
          case("debug")
             config%option%debug = 1
          case("debug=":"debug=:")  ! ':' is the next character of '9' in ascii code table 
             read(unit=argv(8:),fmt=*) config%option%debug
          case("verbose")
             config%option%verbose = 1
          case("verbose=":"verbose=:")
             read(unit=argv(10:),fmt=*) config%option%verbose
          case("quiet")
             config%option%verbose = 0
          case("log_node_number=":"log_node_number=:")
             read(unit=argv(18:),fmt=*) config%option%log_node_number
          case default
             write(*,*) "Error! : unknown option : ", trim(argv)
             write(*,*) "   ... in elses_get_arg "
             stop
          end select
       else
          config%option%filename = argv
       end if
    end do
    
    return
  end subroutine elses_process_options
  
  !! if fortran 95 standard becomes common, following definitions
  !! of program units become useless.
  
  !! re-implimentation of command_argument_count function.
  !! comment out this function if unnecessary
  function command_argument_count() result(argc)
    implicit none
    integer :: argc, iargc
    
    argc = iargc()
    if( argc < 0 ) then
       write(*,'(a)') "# Error! : iargc function is not working."
       stop
    end if
    return
  end function command_argument_count
  
  !! re-implimentation of get_command_argument function.
  !! comment out this function if unnecessary
  subroutine get_command_argument(index,argv)
    implicit none
    integer :: index
    character(len=*) :: argv
    
    call getarg(index,argv)
    
    return
  end subroutine get_command_argument

end module M_options