subroutine nksic_rot_emin_cg_general(nouter, init_n, ninner, etot, rot_threshold, &
                                     nbsp, nbspx, nudx, iupdwn, nupdwn, ispin, c0, becsum, bec, rhor, rhoc, &
                                     vsic, pink, deeq_sic, wtot, fsic, sizwtot, do_wxd, wfc_centers, wfc_spreads, is_empty )
      !
      ! ... Finds the orthogonal rotation matrix Omattot that minimizes
      !     the orbital-dependent and hence the total energy, and then
      !     rotate the wavefunction c0 accordingly using cg minimization.
      !     We may need Omattot for further rotation of the gradient for outer loop CG.
      !     Right now we do not do that because we set resetcg=.true. after inner loop
      !     minimization routine, i.e., setting the search direction to be gradient direction.
      !     (Ultrasoft pseudopotential case is not implemented.)
      !
      use kinds,                      only : dp
      use io_global,                  only : stdout, ionode
      use fft_interfaces,             only : fwfft, invfft
      use fft_base,                   only : dffts, dfftp
      use gvecw,                      only : ngw
      use electrons_base,             only : nspin
      use electrons_module,           only : icompute_spread
      use ions_base,                  only : nsp, nat
      use uspp_param,                 only : nhm
      use nksic,                      only : esic_conv_thr,&
                                             innerloop_cg_nsd,&
                                             innerloop_cg_nreset,&
                                             innerloop_nmax,&
                                             innerloop_atleast
      use uspp,                       only : nkb
      use cg_module,                  only : tcg
      !
      implicit none
      !
      ! in/out vars
      !
      logical                  :: is_empty
      integer                  :: nouter, ninner, init_n 
      integer                  :: nbsp, nbspx, nudx, sizwtot
      integer                  :: ispin(nbspx)
      integer,     intent(in)  :: iupdwn(nspin), nupdwn(nspin)
      real(dp),    intent(in)  :: etot
      real(dp), intent(in)     :: rot_threshold
      real(dp),    intent(in)  :: becsum( nhm*(nhm+1)/2, nat, nspin)
      real(dp),    intent(in)  :: fsic(nbspx)
      real(dp)                 :: rhor(dfftp%nnr,nspin)
      real(dp),    intent(in)  :: rhoc(dfftp%nnr)
      real(dp),    intent(out) :: vsic(dfftp%nnr,nbspx), wtot(sizwtot,2)
      real(dp),    intent(out) :: deeq_sic(nhm,nhm,nat,nbspx)
      logical,     intent(in)  :: do_wxd
      complex(dp), intent(inout) :: c0(ngw,nbspx)
      real(dp),    intent(inout) :: pink(nbspx)
      real(dp),    intent(inout) :: bec(nkb, nbspx)
      real(dp) :: wfc_centers(4,nudx,nspin)
      real(dp) :: wfc_spreads(nudx,nspin,2)
      !
      ! local variables for cg routine
      !
      integer     :: nbnd1, nbnd2, nnrx
      integer     :: isp
      integer     :: nfile
      integer     :: nidx1,nidx2
      integer     :: iter3, nfail
      integer     :: maxiter3, numok, minsteps
      ! 
      real(dp)    :: dtmp
      real(dp)    :: ene0,ene1,enesti,enever,dene0
      real(dp)    :: passo,passov,passof,passomax,spasso
      real(dp)    :: vsicah2sum,vsicah2sum_prev
      real(dp)    :: dPI,dalpha,dmaxeig,deigrms
      real(dp)    :: pinksumprev,passoprod
      real(dp)    :: signalpha
      real(dp)    :: conv_thr
      !
      real(dp),    allocatable :: Heigbig(:)
      real(dp),    allocatable :: Heig(:)
      real(dp),    allocatable :: vsic1(:,:), vsic2(:,:)
      real(dp),    allocatable :: pink1(:), pink2(:)
      ! 
      complex(dp), allocatable :: Umatbig(:,:)
      complex(dp), allocatable :: Omat1tot(:,:), Omat2tot(:,:)
      complex(dp), allocatable :: Omattot(:,:)
      complex(dp), allocatable :: wfc_ctmp(:,:), wfc_ctmp2(:,:)
      complex(dp), allocatable :: gi(:,:), hi(:,:)
      !
      complex(dp), allocatable :: Umat(:,:)
      complex(dp), allocatable :: vsicah(:,:)
      !
      real(dp), allocatable    :: bec1(:,:), bec2(:,:)
      !
      logical     :: restartcg_innerloop, ene_ok_innerloop, ltresh, setpassomax
      logical     :: ldotest
      character(len=4) :: marker
      !
      ! for numerial derivative testing
      !
      integer  :: i
      real(dp) :: odd_test1, odd_test2, tmppasso
      !
      ! main body
      !
      CALL start_clock( 'nk_rot_emin' )
      !
      nnrx = dfftp%nnr
      !
      marker = "^-^"
      maxiter3 = 4
      minsteps = 2
      restartcg_innerloop = .true.
      ene_ok_innerloop    = .false.
      ltresh=.false.
      setpassomax=.false.
      nfail=0
      numok=0
      !
      if(nouter<init_n) then
        ! 
        conv_thr=esic_conv_thr
        !
      else
        !
        conv_thr=rot_threshold
        !
      endif
      !
      pinksumprev=1.d8
      dPI = 2.0_DP * asin(1.0_DP)
      passoprod = 0.3d0
      !
      ! local workspace
      !
      allocate( Omat1tot(nbspx,nbspx), Omat2tot(nbspx,nbspx), Omattot(nbspx,nbspx))
      allocate( Umatbig(nbspx,nbspx) )
      allocate( Heigbig(nbspx) )
      allocate( wfc_ctmp(ngw,nbspx), wfc_ctmp2(ngw,nbspx) )
      allocate( hi(nbsp,nbsp) )
      allocate( gi(nbsp,nbsp) )
      allocate( pink1(nbspx), pink2(nbspx) )
      allocate( vsic1(nnrx,nbspx), vsic2(nnrx,nbspx) )
      ! 
      allocate(bec1(nkb,nbsp))
      allocate(bec2(nkb,nbsp))
      !
      Umatbig(:,:)=CMPLX(0.d0,0.d0)
      Heigbig(:)=0.d0
      deigrms = 0.d0
      hi(:,:) = 0.d0
      gi(:,:) = 0.d0
      !
      Omattot(:,:)=CMPLX(0.d0,0.d0)
      do nbnd1=1,nbspx
         ! 
         Omattot(nbnd1,nbnd1)=CMPLX(1.d0,0.d0)
         !
      enddo
      !
      ninner = 0
      ldotest=.false.
      !
      if (ionode) write(stdout, "(14x,'# iter',6x,'etot',17x,'esic',17x,'deigrms', 17x,'Pede_cond')")
      !
      ! main loop
      !
      inner_loop: &
      do while (.true.)
        ! 
        call start_clock( "nk_innerloop" )
        !
        ninner = ninner + 1
        !   
        if ( ninner > innerloop_nmax ) then
           !
           if (ionode) then
              !
              write(stdout,"(14x,'# innerloop_nmax reached.',/)")
              ! 
           endif
           !
           call stop_clock( "nk_innerloop" )
           ! 
           exit inner_loop
           !
        endif
        !  
        ! print out ESIC part & other total energy
        !
        ene0 = sum( pink(1:nbsp) )
        !
        ! test convergence
        !
        if ( abs(ene0-pinksumprev) < conv_thr ) then
           !
           numok=numok+1
           !
        else
           ! 
           numok=0
           !
        endif
        !
        if (numok >= minsteps .and. ninner>=innerloop_atleast) ltresh=.true.
        !
        if (ltresh) then
           !
           if (ionode) then
              !  
              write(stdout,"(a,/)") '# inner-loop converged.'
              write(stdout,"(a,/)") '# inner-loop converged.'
              !
           endif
           !
           call stop_clock( "nk_innerloop" )
           !
           exit inner_loop
           !
        endif
        !
        pinksumprev=ene0
        !
        ! This part calculates the anti-hermitian part of the Hamiltonian vsicah
        ! and see whether a convergence has been achieved
        !
        ! For this run, we obtain the gradient
        !
        vsicah2sum = 0.0d0
        !
        do isp=1,nspin
           !
           allocate(vsicah(nupdwn(isp),nupdwn(isp)))
           !
           call nksic_getvsicah_general(ngw, nbsp, nbspx, c0, &
                     bec, isp, nupdwn, iupdwn, vsic, deeq_sic, vsicah, dtmp) 
           !
           gi(iupdwn(isp):iupdwn(isp)-1+nupdwn(isp), &
              iupdwn(isp):iupdwn(isp)-1+nupdwn(isp)) = vsicah(:,:)
           !
           vsicah2sum = vsicah2sum + dtmp
           !
           deallocate(vsicah)
           !
        enddo
        !
        if ( ninner /= 1 ) dtmp = vsicah2sum/vsicah2sum_prev
        !
        if ( ninner <= innerloop_cg_nsd .or. &
           mod(ninner,innerloop_cg_nreset) ==0 .or. restartcg_innerloop ) then
           !
           restartcg_innerloop=.false.
           setpassomax=.false.
           !
           hi(:,:) = gi(:,:)
           ! 
        else
           !
           hi(:,:) = gi(:,:) + dtmp*hi(:,:)
           !
        endif
        !
        spin_loop: &
        do isp=1,nspin
           !
           if (nupdwn(isp).gt.0) then
              !  
              allocate( vsicah(nupdwn(isp),nupdwn(isp)) )
              allocate( Umat(nupdwn(isp),nupdwn(isp)) )
              allocate( Heig(nupdwn(isp)) )
              !
              vsicah(:,:) = hi( iupdwn(isp):iupdwn(isp)-1+nupdwn(isp), &
                             iupdwn(isp):iupdwn(isp)-1+nupdwn(isp) )
              !
              call nksic_getHeigU_general(isp, nupdwn, vsicah, Heig, Umat) 
              !
              deigrms = deigrms + sum(Heig(:)**2)
              !
              Umatbig( iupdwn(isp):iupdwn(isp)-1+nupdwn(isp), &
                       iupdwn(isp):iupdwn(isp)-1+nupdwn(isp) ) = Umat(:,:)
              Heigbig( iupdwn(isp):iupdwn(isp)-1+nupdwn(isp) ) = Heig(:)
              !
              deallocate(vsicah)
              deallocate(Umat)
              deallocate(Heig)
              !
           else
              !
              Umatbig( iupdwn(isp):iupdwn(isp)-1+nupdwn(isp), &
                       iupdwn(isp):iupdwn(isp)-1+nupdwn(isp) ) = 1.d0
              Heigbig( iupdwn(isp):iupdwn(isp)-1+nupdwn(isp) ) = 0.d0
              !
           endif 
           !
        enddo spin_loop
        !
        ! how severe the transform is
        !
        deigrms = sqrt(deigrms/nbsp)
        ! 
        if(ionode) write(stdout,'(10x,A3,2i4,4F18.13)') marker, ninner, nouter, etot, ene0, deigrms, vsicah2sum
        !
        dmaxeig = max(dabs(Heigbig(iupdwn(1))), dabs(Heigbig(iupdwn(1)+nupdwn(1)-1)))
        !
        do isp = 2, nspin
           !
           dmaxeig = max(dmaxeig,dabs(Heigbig(iupdwn(isp))))
           dmaxeig = max(dmaxeig,dabs(Heigbig(iupdwn(isp)+nupdwn(isp)-1)))
           ! 
        enddo
        !
        passomax=passoprod/dmaxeig
        !
        if ( ninner == 1 .or. setpassomax) then
           !
           passof = passomax
           setpassomax=.false.
           ! 
           if(ionode) write(stdout,*) '# passof set to passomax'
           !
        endif
        ! 
        vsicah2sum_prev = vsicah2sum
        !
        dene0 = 0.d0
        !
        do isp = 1, nspin
           !
           do nbnd1 = 1, nupdwn(isp)
              !  
              do nbnd2 = 1, nupdwn(isp)
                 !
                 nidx1 = nbnd1-1+iupdwn(isp)
                 nidx2 = nbnd2-1+iupdwn(isp)
                 !
                 if (nidx1.ne.nidx2) then
                    !
                    dene0 = dene0 - DBLE(CONJG(gi(nidx1,nidx2))*hi(nidx1,nidx2))
                    !
                 endif
                 !
              enddo
              !
           enddo
           !
        enddo
        !
        ! Be careful, the following is correct because A_ji = - A_ij, i.e., the number of
        ! linearly independent variables is half the number of total variables!
        !
        dene0 = dene0 * 1.d0/nspin
        !
        spasso = 1.d0
        !  
        if( dene0 > 0.d0) spasso = -1.d0
        !
        ! here is for testing: compare numerical and analytical derivates  
        !
        if (.false.) then
           !
           odd_test1 = 0.0
           odd_test2 = 0.0
           !
           do i=1,2
              !
              if (i==1)  tmppasso=1.d-3
              if (i==2)  tmppasso=-1.d-3
              !
              dalpha = spasso*tmppasso
              !
              call nksic_getOmattot_general( nbsp, nbspx,nudx,ispin, &
                               iupdwn, nupdwn, wfc_centers, wfc_spreads, &
                               dalpha, Heigbig, Umatbig, &
                               c0, wfc_ctmp, Omat1tot, bec1, rhor, rhoc, &
                               becsum, deeq_sic, wtot, fsic, sizwtot, do_wxd, &
                               vsic1, pink1, ene1, is_empty)
              if (i==1) odd_test1 = ene1
              if (i==2) odd_test2 = ene1
           enddo
           !
           write(stdout, *) " odd_test1  odd_test2 ", odd_test1, odd_test2, dene0
           write(stdout, *) "ratio bw numerial and analytic derivative = ", ((odd_test1-odd_test2)/(tmppasso*2.0))/dene0
           write(stdout, *) "ratio bw numerial and analytic derivative = ", ((odd_test1-ene0)/(tmppasso))/dene0
           !
        endif 
        !
        dalpha = spasso*passof
        !
        call nksic_getOmattot_general( nbsp, nbspx,nudx,ispin, &
                               iupdwn, nupdwn, wfc_centers, wfc_spreads, &
                               dalpha, Heigbig, Umatbig, &
                               c0, wfc_ctmp, Omat1tot, bec1, rhor, rhoc, &
                               becsum, deeq_sic, wtot, fsic, sizwtot, do_wxd, &
                               vsic1, pink1, ene1, is_empty)
        !
        call minparabola( ene0, spasso*dene0, ene1, passof, passo, enesti)
        !
        ! We neglect this step for paper writing purposes
        !
        if ( passo > passomax ) then
           !
           passo = passomax
           ! 
           if(ionode) write(stdout,*) '# passo > passomax'
           !
        endif
        !
        passov = passof
        !
        passof = 2.d0*passo
        !
        dalpha = spasso*passo
        !
        call nksic_getOmattot_general( nbsp, nbspx,nudx,ispin, &
                               iupdwn, nupdwn, wfc_centers, wfc_spreads, &
                               dalpha, Heigbig, Umatbig, &
                               c0, wfc_ctmp2, Omat2tot, bec2, rhor, rhoc, &
                               becsum, deeq_sic, wtot, fsic, sizwtot, do_wxd, &
                               vsic2, pink2, enever, is_empty)
        !
        if (ene0 < ene1 .and. ene0 < enever) then !missed minimum case 3
           !
           write(stdout ,'("# WARNING: innerloop missed minimum, case 3",/)')
           ! 
           iter3=0
           signalpha=1.d0
           restartcg_innerloop=.true.
           !
           do while(enever.ge.ene0 .and. iter3.lt.maxiter3)
              !
              iter3=iter3+1
              !
              signalpha=signalpha*(-0.717d0)
              !  
              dalpha = spasso*passo*signalpha
              !
              call nksic_getOmattot_general( nbsp, nbspx,nudx,ispin, &
                               iupdwn, nupdwn, wfc_centers, wfc_spreads, &
                               dalpha, Heigbig, Umatbig, &
                               c0, wfc_ctmp2, Omat2tot, bec2, rhor, rhoc, &
                               becsum, deeq_sic, wtot, fsic, sizwtot, do_wxd, &
                               vsic2, pink2, enever, is_empty)
              !
           enddo
           !
           if (enever.lt.ene0) then
              !
              pink(:)   = pink2(:)
              vsic(:,:) = vsic2(:,:)
              c0(:,:)   = wfc_ctmp2(:,:)
              !call copy_twin(bec,bec2)
              call dcopy(nkb*nbsp, bec, 1, bec2, 1)
              Omattot   = MATMUL( Omattot, Omat2tot)
              !  
              write(stdout,'(i1)') iter3
              marker = '*'//marker
              passof=passo*abs(signalpha)
              nfail=0
              !
            else
              !
              marker = '^^'
              ninner = ninner + 1
              nfail=nfail+1
              numok=0
              passof=passo*abs(signalpha)
              !
              if (nfail>2) then
                 !
                 write(stdout,'("# WARNING: innerloop not converged, exit",/)')
                 call stop_clock( "nk_innerloop" )
                 exit
              endif
              !
           endif
           !
        elseif( ene1 >= enever ) then !found minimum
           !
           pink(:)   = pink2(:)
           vsic(:,:) = vsic2(:,:)
           c0(:,:)   = wfc_ctmp2(:,:)
           !call copy_twin(bec,bec2)
           call dcopy(nkb*nbsp, bec, 1, bec2, 1)
           Omattot   = MATMUL( Omattot, Omat2tot)
           marker = "^_^"
           nfail  = 0
           !
        else !missed minimum, case 1 or 2
           !
           write(stdout,'("# WARNING: innerloop missed minimum case 1 or 2",/)')
           ! 
           pink(:)   = pink1(:)
           vsic(:,:) = vsic1(:,:)
           c0(:,:)   = wfc_ctmp(:,:)
           !call copy_twin(bec,bec1)
           call dcopy(nkb*nbsp, bec, 1, bec1, 1)
           Omattot   = MATMUL( Omattot, Omat1tot)
           restartcg_innerloop = .true.
           !
           if (enever<ene0) then
              ! 
              marker="*  "
              passof=min(1.5d0*passov,passomax)
              !
           else
              !
              marker="** "
              passof=passov
              ! 
           endif
           !
           nfail=0
           !
        endif
        !
        call stop_clock( "nk_innerloop" )
        !
      enddo  inner_loop
      !
      ! clean local workspace
      !
      deallocate( Omat1tot, Omat2tot )
      deallocate( Umatbig )
      deallocate( Heigbig )
      deallocate( wfc_ctmp, wfc_ctmp2 )
      deallocate( hi )
      deallocate( gi )
      deallocate( pink1, pink2 )
      deallocate( vsic1, vsic2 )
      deallocate( bec1 )
      deallocate( bec2 )
      !
      call stop_clock( 'nk_rot_emin' )
      !  
      return
      !
end subroutine nksic_rot_emin_cg_general
!
!
!
subroutine nksic_getvsicah_general(ngw, nbsp, nbspx, c0, bec, &
                              isp, nupdwn, iupdwn, vsic, deeq_sic, vsicah, vsicah2sum)
      !
      ! ... Calculates the anti-hermitian part of the SIC hamiltonian, vsicah.
      !     makes use of nksic_eforce to compute   h_i | phi_i >
      !     and then computes   < phi_j | h_i | phi_i >  in reciprocal space.
      !
      use kinds,                      only : dp
      use io_global,                  only : stdout
      use gvect,                      only : ngm, gstart      
      use mp,                         only : mp_sum
      use mp_global,                  only : intra_bgrp_comm
      use fft_interfaces,             only : fwfft, invfft
      use fft_base,                   only : dffts, dfftp
      use uspp_param,                 only : nhm
      use ions_base,                  only : nat
      use electrons_base,             only : nspin
      use uspp,                       only : nkb
      !
      implicit none
      !
      ! in/out vars
      !
      integer,     intent(in)  :: isp, ngw, nbsp, nbspx, &
                                  nupdwn(nspin), iupdwn(nspin)
      real(dp)                 :: vsicah2sum
      real(dp)                 :: vsic(dfftp%nnr,nbspx) 
      real(dp)                 :: deeq_sic(nhm, nhm, nat, nbspx) 
      complex(dp)              :: vsicah( nupdwn(isp),nupdwn(isp)), c0(ngw, nbsp)
      real(dp)                 :: bec(nkb, nbspx)
      !
      ! local variables
      !
      integer         :: nbnd1, nbnd2, nnrx 
      integer         :: i, j1, jj1, j2, jj2
      real(dp)        :: vsicahtmp, cost
      complex(dp),    allocatable :: hmat(:,:)
      complex(dp),    allocatable :: vsicpsi(:,:)
      !   
      call start_clock('nk_get_vsicah')
      !
      nnrx = dfftp%nnr
      !
      !cost  = DBLE( nspin ) * 2.0d0
      cost  =  2.0d0
      !
      allocate( hmat(nupdwn(isp),nupdwn(isp)) )
      allocate( vsicpsi(ngw,2) )
      !
      ! compute < phi_j | Delta h_i | phi_i >
      !
      do nbnd1 = 1, nupdwn(isp), 2
         !
         ! NOTE: USPP not implemented
         !
         j1 = nbnd1+iupdwn(isp)-1
         ! 
         call nksic_eforce( j1, nbsp, nbspx, vsic, &
                             deeq_sic, bec, ngw, c0(:,j1), c0(:,j1+1), vsicpsi )
         !
         do jj1 = 1, 2
            !
            if ( nbnd1+jj1-1 > nupdwn(isp) ) cycle
            !
            do nbnd2 = 1, nupdwn(isp)
               !
               j2 = nbnd2+iupdwn(isp)-1
               !  
               hmat(nbnd2,nbnd1+jj1-1) = 2.d0*DBLE(DOT_PRODUCT( c0(:,j2), vsicpsi(:,jj1)))
               !
               if ( gstart == 2 ) then
                  ! 
                  hmat(nbnd2,nbnd1+jj1-1) = hmat(nbnd2,nbnd1+jj1-1) - &
                            DBLE( c0(1,j2) * vsicpsi(1,jj1) )
               endif
               !
               !
            enddo
            !
         enddo
         !  
      enddo
      !
      call mp_sum( hmat, intra_bgrp_comm )
      ! 
      hmat = hmat * cost
      !
      ! Imposing Pederson condition
      !
      vsicah(:,:) = 0.0d0
      vsicah2sum  = 0.0d0
      !
      do nbnd1 = 1, nupdwn(isp)
         !
         do nbnd2 = 1, nbnd1-1
           !
           vsicah( nbnd2, nbnd1) = DBLE(hmat(nbnd2,nbnd1) -CONJG(hmat(nbnd1,nbnd2)))
	   vsicah( nbnd1, nbnd2) = DBLE(hmat(nbnd1,nbnd2) -CONJG(hmat(nbnd2,nbnd1)))
           !
           vsicah2sum =  vsicah2sum + DBLE(CONJG(vsicah(nbnd2,nbnd1))*vsicah(nbnd2,nbnd1))
           !
        enddo
        !
      enddo
      !
      deallocate( hmat )
      deallocate( vsicpsi )
      !
      call stop_clock('nk_get_vsicah')
      !
      return
      ! 
end subroutine nksic_getvsicah_general
!
!
!
subroutine nksic_getHeigU_general(isp, nupdwn, vsicah, Heig, Umat)
      !
      ! ... solves the eigenvalues (Heig) and eigenvectors (Umat) of the force
      !     matrix vsicah.
      !     (Ultrasoft pseudopotential case is not implemented.)
      !
      use kinds,                      only : dp
      use mp,                         only : mp_bcast
      use mp_global,                  only : intra_image_comm
      use io_global,                  only : ionode, ionode_id
      use electrons_base,             only : nspin
      !
      implicit none
      !
      ! in/out vars
      !
      integer,     intent(in)  :: isp, nupdwn(nspin)
      real(dp)     :: Heig(nupdwn(isp))
      complex(dp)  :: Umat(nupdwn(isp),nupdwn(isp))
      complex(dp)  :: vsicah(nupdwn(isp),nupdwn(isp))
      !
      ! local variables
      !
      complex(dp)              :: Hmat(nupdwn(isp),nupdwn(isp))
      complex(dp)              :: ci
      ! 
      ci = CMPLX(0.d0,1.d0)
      !
      ! this part diagonalizes Hmat = iWmat
      !
      Hmat(:,:) = ci * vsicah(:,:)
      !
      ! diagonalize Hmat
      ! 
      CALL zdiag(nupdwn(isp),nupdwn(isp),Hmat(1,1),Heig(1),Umat(1,1),1)
      !   
      return
      !
end subroutine nksic_getHeigU_general
!
!
!
subroutine nksic_getOmattot_general(nbsp,nbspx,nudx,ispin, &
                   iupdwn,nupdwn,wfc_centers,wfc_spreads, &
                   dalpha,Heigbig,Umatbig, &
                   wfc0, wfc1,Omat1tot,bec1, rhor, rhoc, &
                   becsum, deeq_sic, wtot, fsic, sizwtot, do_wxd, &
                   vsic1,pink1,ene1,is_empty)
      !
      ! ... This routine rotates the wavefunction wfc0 into wfc1 according to
      !     the force matrix (Heigbig, Umatbig) and the step of size dalpha.
      !     Other quantities such as bec, vsic, pink are also calculated for wfc1.
      !
      use kinds,                      only : dp
      use io_global,                  only : stdout, ionode
      use gvecw,                      only : ngw
      use ions_base,                  only : nsp, nat
      use electrons_base,             only : nspin
      use uspp_param,                 only : nhm
      use cp_main_variables,          only : eigr
      use electrons_module,           only : icompute_spread
      use cp_interfaces,              only : nlsm1
      use uspp,                       only : nkb
      use fft_base,                   only : dffts, dfftp

      !
      implicit none
      !
      ! in/out vars
      !
      integer,            intent(in) :: nbsp, nbspx, nudx
      integer,            intent(in) :: ispin(nbspx), nupdwn(nspin), &
                                        iupdwn(nspin)
      real(dp),           intent(in) :: dalpha
      complex(dp),        intent(in) :: Umatbig(nbspx,nbspx)
      real(dp),           intent(in) :: Heigbig(nbspx), wfc_centers(4,nudx,nspin),&
                                        wfc_spreads(nudx,nspin,2)
      complex(dp),        intent(in) :: wfc0(ngw,nbspx)
      !
      complex(dp)                    :: wfc1(ngw,nbspx)
      complex(dp)                    :: Omat1tot(nbspx,nbspx)
      real(dp)                       :: bec1(nkb,nbspx) 
      real(dp)                       :: vsic1(dfftp%nnr,nbspx)
      real(dp)                       :: pink1(nbspx)
      real(dp)                       :: ene1
      integer,            intent(in) :: sizwtot
      real(dp),           intent(in) :: becsum( nhm*(nhm+1)/2, nat, nspin)
      real(dp),           intent(in) :: deeq_sic(nhm,nhm,nat,nbspx) 
      real(dp),           intent(in) :: wtot(sizwtot,2)
      real(dp),           intent(in) :: fsic(nbspx)
      real(dp),           intent(in) :: rhor(dfftp%nnr,nspin)
      real(dp),           intent(in) :: rhoc(dfftp%nnr)
      logical,            intent(in) :: do_wxd
      logical,            intent(in) :: is_empty
      !
      ! local variables for cg routine
      !
      integer    :: isp, nbnd1, nnrx
      real(dp)   :: dmaxeig
      complex(dp),    allocatable :: Omat1(:,:)
      complex(dp), allocatable :: Umat(:,:)
      real(dp),    allocatable :: Heig(:)
      !
      call start_clock( "nk_getOmattot" )
      !
      Omat1tot(:,:) = 0.d0
      !
      do nbnd1=1,nbspx
         ! 
         Omat1tot(nbnd1,nbnd1)=1.d0
         !
      enddo
      ! 
      wfc1(:,:) = CMPLX(0.d0,0.d0)
      !
      dmaxeig = max( abs(Heigbig(iupdwn(1))), abs(Heigbig(iupdwn(1)+nupdwn(1)-1)) )
      ! 
      do isp=2,nspin
         !
         dmaxeig = max(dmaxeig,abs(Heigbig(iupdwn(isp))))
         dmaxeig = max(dmaxeig,abs(Heigbig(iupdwn(isp)+nupdwn(isp)-1)))
         !
      enddo
      !
      spin_loop: &
      do isp=1,nspin
         !
         if (nupdwn(isp).gt.0) then
            !
            allocate(Umat(nupdwn(isp),nupdwn(isp)))
            allocate(Heig(nupdwn(isp)))
            allocate(Omat1(nupdwn(isp),nupdwn(isp)))
            !
            Umat(:,:) = Umatbig(iupdwn(isp):iupdwn(isp)-1+nupdwn(isp),iupdwn(isp):iupdwn(isp)-1+nupdwn(isp))
            Heig(:) = Heigbig(iupdwn(isp):iupdwn(isp)-1+nupdwn(isp))
            !
            call nksic_getOmat1_general(nupdwn(isp),Heig,Umat,dalpha,Omat1)
            ! 
            ! Wavefunction wfc0 is rotated into wfc1 using Omat1
            ! 
            call nksic_rotwfn_general(nbspx,nupdwn(isp),iupdwn(isp),Omat1,wfc0,wfc1)
            !
            ! Assigning the rotation matrix for a specific spin isp
            !
            Omat1tot(iupdwn(isp):iupdwn(isp)-1+nupdwn(isp),iupdwn(isp):iupdwn(isp)-1+nupdwn(isp)) = Omat1(:,:)
            ! 
            deallocate(Umat)
            deallocate(Heig)
            deallocate(Omat1)
            !
         else
            !
            Omat1tot(iupdwn(isp):iupdwn(isp)-1+nupdwn(isp),iupdwn(isp):iupdwn(isp)-1+nupdwn(isp)) = 1.d0
            !
         endif
         !
      enddo spin_loop
      !
      ! recalculate bec & vsic according to the new wavefunction
      !
      call nlsm1 ( nbsp, 1, nsp, eigr, wfc1, bec1 )
      ! 
      vsic1(:,:) = 0.0_dp
      pink1(:) = 0.0_dp
      !
      call nksic_potential( nbsp, nbspx, wfc1, fsic, bec1, becsum, deeq_sic, &
                 ispin, iupdwn, nupdwn, rhor, rhoc, wtot, sizwtot, vsic1, do_wxd, pink1, nudx, wfc_centers, &
                 wfc_spreads, icompute_spread, is_empty )
      !
      ene1=sum(pink1(:))
      !
      call stop_clock( "nk_getOmattot" )
      !
      return
      !
end subroutine nksic_getOmattot_general
!
!
subroutine nksic_getOmat1_general(nupdwn_isp,Heig,Umat,passof,Omat1)
!
! ... Obtains the rotation matrix from the force-related matrices Heig and Umat
!     and also from the step size (passof).
!
      use kinds,                      only : dp
      !
      implicit none
      !
      ! in/out vars
      !
      integer,      intent(in) :: nupdwn_isp
      real(dp),     intent(in) :: Heig(nupdwn_isp)
      complex(dp),  intent(in) :: Umat(nupdwn_isp,nupdwn_isp)
      real(dp),     intent(in) :: passof
      complex(dp)              :: Omat1(nupdwn_isp,nupdwn_isp)
      !
      ! local variables
      !
      complex(dp) :: Cmattmp(nupdwn_isp,nupdwn_isp)
      complex(dp) :: exp_iHeig(nupdwn_isp)
      complex(dp) :: ci
      !
      integer     :: nbnd1
      real(dp)    :: dtmp
      ! 
      call start_clock ( "nk_getOmat1" )
      !
      !$$ We set the step size in such a way that the phase change
      !$$ of the wavevector with largest eigenvalue upon rotation is fixed
      !      passof = passoprod/max(abs(Heig(1)),abs(Heig(nupdwn(isp))))
      !$$ Now the above step is done outside.
      !
      ci = (0.0_dp,1.0_dp)
      !
      do nbnd1=1,nupdwn_isp
         !
         dtmp =  passof * Heig(nbnd1)
         exp_iHeig(nbnd1) = DCOS(dtmp) + ci*DSIN(dtmp)
         !   
      enddo
      !
      ! Cmattmp = exp(i * passof * Heig) * Umat^dagger   ; Omat = Umat * Cmattmp
      !
      do nbnd1=1, nupdwn_isp
         ! 
         Cmattmp(nbnd1,:) = exp_iHeig(nbnd1)*CONJG(Umat(:,nbnd1))
         !
      enddo
      ! 
      Omat1 = DBLE(MATMUL( Umat, Cmattmp)) !modified:giovanni
      !  
      call stop_clock ( "nk_getOmat1" )
      !
      return
      !
end subroutine nksic_getOmat1_general
!
!
!
subroutine nksic_rotwfn_general(nbspx,nupdwn_isp,iupdwn_isp,Omat1,wfc1,wfc2)
      !
      ! ... Simple rotation of wfc1 into wfc2 by Omat1.
      !     wfc2(n) = sum_m wfc1(m) Omat1(m,n)
      !
      use gvecw,                      only : ngw
      use kinds,                      only : dp
      !
      implicit none
      !
      ! in/out vars
      !
      integer,     intent(in)  :: nbspx, nupdwn_isp, iupdwn_isp
      complex(dp), intent(in)  :: Omat1(nupdwn_isp,nupdwn_isp)
      complex(dp), intent(in)  :: wfc1(ngw,nbspx)
      complex(dp)              :: wfc2(ngw,nbspx)
      !
      ! local variables for cg routine
      !
      integer                  :: nbnd1,nbnd2

      CALL start_clock('nk_rotwfn')
      !
      wfc2(:,iupdwn_isp:iupdwn_isp-1+nupdwn_isp)=CMPLX(0.d0,0.d0)
      !
      ! a blas could be used here XXX
      !
      do nbnd1=1,nupdwn_isp
         !
         do nbnd2=1,nupdwn_isp
            !
            wfc2(:,iupdwn_isp-1 + nbnd1)=wfc2(:,iupdwn_isp-1 + nbnd1) &
                   + wfc1(:,iupdwn_isp-1 + nbnd2) * Omat1(nbnd2,nbnd1)
            !
         enddo
         !  
      enddo
      !
      call stop_clock('nk_rotwfn')
      !
      return
      !

end subroutine nksic_rotwfn_general 
