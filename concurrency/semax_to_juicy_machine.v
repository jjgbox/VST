Require Import Coq.Strings.String.

Require Import compcert.lib.Integers.
Require Import compcert.common.AST.
Require Import compcert.cfrontend.Clight.
Require Import compcert.common.Globalenvs.
Require Import compcert.common.Memory.
Require Import compcert.common.Memdata.
Require Import compcert.common.Values.

Require Import msl.Coqlib2.
Require Import msl.eq_dec.
Require Import msl.seplog.
Require Import veric.initial_world.
Require Import veric.juicy_mem.
Require Import veric.juicy_mem_lemmas.
Require Import veric.semax_prog.
Require Import veric.compcert_rmaps.
Require Import veric.Clight_new.
Require Import veric.Clightnew_coop.
Require Import veric.semax.
Require Import veric.semax_ext.
Require Import veric.juicy_extspec.
Require Import veric.initial_world.
Require Import veric.juicy_extspec.
Require Import veric.tycontext.
Require Import veric.semax_ext.
Require Import veric.semax_ext_oracle.
Require Import veric.res_predicates.
Require Import veric.mem_lessdef.
Require Import floyd.coqlib3.
Require Import sepcomp.semantics.
Require Import sepcomp.step_lemmas.
Require Import sepcomp.event_semantics.
Require Import concurrency.coqlib5.
Require Import concurrency.semax_conc.
Require Import concurrency.sync_preds.
Require Import concurrency.juicy_machine.
Require Import concurrency.concurrent_machine.
Require Import concurrency.scheduler.
Require Import concurrency.addressFiniteMap.
Require Import concurrency.permissions.
Require Import concurrency.JuicyMachineModule.
Require Import concurrency.age_to.
Require Import concurrency.join_lemmas.

Set Bullet Behavior "Strict Subproofs".

Ltac eassert :=
  let mp := fresh "mp" in
  pose (mp := fun {goal Q : Type} (x : goal) (y : goal -> Q) => y x);
  eapply mp; clear mp.

Ltac range_tac :=
  match goal with
    H : ~ adr_range (?b, _) _ (?b, _) |- _ =>
    exfalso; apply H;
    repeat split; auto;
    try unfold Int.unsigned;
    unfold lock_size;
    omega
  end.

Open Scope string_scope.

(*! Instantiation of modules *)
Import THE_JUICY_MACHINE.
Import JSEM.
Module Machine :=THE_JUICY_MACHINE.JTP.
Definition schedule := SCH.schedule.
Import JuicyMachineLemmas.
Import ThreadPool.

Ltac cleanup :=
  unfold lockRes in *;
  unfold LocksAndResources.lock_info in *;
  unfold LocksAndResources.res in *;
  unfold lockGuts in *.

(*+ Description of the invariant *)

Definition cm_state := (Mem.mem * Clight.genv * (schedule * Machine.t))%type.

(*! Coherence between locks in dry/wet memories and lock pool *)

Inductive cohere_res_lock : forall (resv : option (option rmap)) (wetv : resource) (dryv : memval), Prop :=
| cohere_notlock wetv dryv:
    (forall sh sh' z P, wetv <> YES sh sh' (LK z) P) ->
    cohere_res_lock None wetv dryv
| cohere_locked R wetv :
    islock_pred R wetv ->
    cohere_res_lock (Some None) wetv (Byte (Integers.Byte.zero))
| cohere_unlocked R phi wetv :
    islock_pred R wetv ->
    R phi ->
    cohere_res_lock (Some (Some phi)) wetv (Byte (Integers.Byte.one)).

Definition LKspec_ext (R: pred rmap) : spec :=
   fun (rsh sh: Share.t) (l: AV.address)  =>
    allp (jam (adr_range_dec l lock_size)
                         (jam (eq_dec l) 
                            (yesat (SomeP nil (fun _ => R)) (LK lock_size) rsh sh)
                            (CTat l rsh sh))
                         (fun _ => TT)).

Definition LK_at R sh :=
  LKspec_ext R (Share.unrel Share.Lsh sh) (Share.unrel Share.Rsh sh).

Definition load_at m loc := Mem.load Mint32 m (fst loc) (snd loc).

Definition lock_coherence (lset : AMap.t (option rmap)) (phi : rmap) (m : mem) : Prop :=
  forall loc : address,
    match AMap.find loc lset with
    
    (* not a lock *)
    | None =>
      forall sh sh' z P,
        phi @ loc <> YES sh sh' (LK z) P /\
        phi @ loc <> YES sh sh' (CT z) P
    
    (* locked lock *)
    | Some None =>
      load_at m loc = Some (Vint Int.zero) /\
      exists sh R, LK_at R sh loc phi
    
    (* unlocked lock *)
    | Some (Some lockphi) =>
      load_at m loc = Some (Vint Int.one) /\
      exists sh (R : mpred),
        LK_at R sh loc phi /\
        (app_pred R (age_by 1 lockphi) \/ level phi = O)
        (*/\
        match age1 lockphi with
        | Some p => app_pred R p
        | None => Logic.True
        end*)
    end.

Definition far (ofs1 ofs2 : Z) := (Z.abs (ofs1 - ofs2) >= 4)%Z.

Lemma far_range ofs ofs' z :
  (0 <= z < 4)%Z ->
  far ofs ofs' ->
  ~(ofs <= ofs' + z < ofs + size_chunk Mint32)%Z.
Proof.
  unfold far; simpl.
  intros H1 H2.
  zify.
  omega.
Qed.

Definition lock_sparsity {A} (lset : AMap.t A) : Prop :=
  forall loc1 loc2,
    AMap.find loc1 lset <> None ->
    AMap.find loc2 lset <> None ->
    loc1 = loc2 \/
    fst loc1 <> fst loc2 \/
    (fst loc1 = fst loc2 /\ far (snd loc1) (snd loc2)).

Lemma lock_sparsity_age_to tp n :
  lock_sparsity (lset tp) -> 
  lock_sparsity (lset (age_tp_to n tp)).
Proof.
  destruct tp as [A B C lset0]; simpl.
  intros S l1 l2 E1 E2; apply (S l1 l2).
  - rewrite AMap_find_map_option_map in E1.
    cleanup.
    destruct (AMap.find (elt:=option rmap) l1 lset0); congruence || tauto.
  - rewrite AMap_find_map_option_map in E2.
    cleanup.
    destruct (AMap.find (elt:=option rmap) l2 lset0); congruence || tauto.
Qed.

Definition lset_same_support {A} (lset1 lset2 : AMap.t A) :=
  forall loc,
    AMap.find loc lset1 = None <->
    AMap.find loc lset2 = None.

Lemma sparsity_same_support {A} (lset1 lset2 : AMap.t A) :
  lset_same_support lset1 lset2 ->
  lock_sparsity lset1 ->
  lock_sparsity lset2.
Proof.
  intros same sparse l1 l2.
  specialize (sparse l1 l2).
  rewrite <-(same l1).
  rewrite <-(same l2).
  auto.
Qed.

Lemma same_support_change_lock {A} (lset : AMap.t A) l x :
  AMap.find l lset <> None ->
  lset_same_support lset (AMap.add l x lset).
Proof.
  intros E l'.
  rewrite AMap_find_add.
  if_tac.
  - split; congruence.
  - tauto.
Qed.

Lemma lset_same_support_map {A} m (f : A -> A) :
  lset_same_support (AMap.map (option_map f) m) m.
Proof.
  intros k.
  rewrite AMap_find_map_option_map.
  destruct (AMap.find (elt:=option A) k m); simpl; split; congruence.
Qed.

Lemma lset_same_support_sym {A} (m1 m2 : AMap.t A) :
  lset_same_support m1 m2 ->
  lset_same_support m2 m1.
Proof.
  unfold lset_same_support in *.
  intros E loc.
  rewrite E; tauto.
Qed.

Lemma lset_same_support_trans {A} (m1 m2 m3 : AMap.t A) :
  lset_same_support m1 m2 ->
  lset_same_support m2 m3 ->
  lset_same_support m1 m3.
Proof.
  unfold lset_same_support in *.
  intros E F loc.
  rewrite E; apply F.
Qed.

(*! Joinability and coherence *)

Lemma mem_compatible_forget {tp m phi} :
  mem_compatible_with tp m phi -> mem_compatible tp m.
Proof. intros M; exists phi. apply M. Qed.

Definition jm_
  {tp m PHI i}
  (cnti : Machine.containsThread tp i)
  (mcompat : mem_compatible_with tp m PHI)
  : juicy_mem :=
  personal_mem cnti (mem_compatible_forget mcompat).

Lemma personal_mem_ext
  tp tp' m
  (compat : mem_compatible tp m)
  (compat' : mem_compatible tp' m)
  (same_threads_rmaps: forall i cnti cnti',
      @Machine.getThreadR i tp cnti =
      @Machine.getThreadR i tp' cnti')
  i
  (cnti : Machine.containsThread tp i)
  (cnti' : Machine.containsThread tp' i) :
    personal_mem cnti compat = personal_mem cnti' compat'.
Proof.
  unfold jm_ in *.
  unfold personal_mem in *; simpl. 
  apply juicy_mem_ext.
  - unfold juicyRestrict in *; simpl.
    apply permissions.restrPermMap_ext.
    intros b; repeat f_equal; auto.
  - unfold personal_mem in *. simpl. auto.
Qed.

(*! Invariant (= above properties + safety + uniqueness of Krun) *)

Definition threads_safety {Z} (Jspec : juicy_ext_spec Z) m ge tp PHI (mcompat : mem_compatible_with tp m PHI) n :=
  forall i (cnti : Machine.containsThread tp i) (ora : Z),
    match Machine.getThreadC cnti with
    | Krun c
    | Kblocked c => semax.jsafeN Jspec ge n ora c (jm_ cnti mcompat)
    | Kresume c v =>
      forall c',
        (* [v] is not used here. The problem is probably coming from
           the definition of JuicyMachine.resume_thread'. *)
        cl_after_external (Some (Vint Int.zero)) c = Some c' ->
        semax.jsafeN Jspec ge n ora c' (jm_ cnti mcompat)
    | Kinit _ _ => Logic.True
    end.

Definition threads_wellformed tp :=
  forall i (cnti : containsThread tp i),
    match getThreadC cnti with
    | Krun q => Logic.True
    | Kblocked q => cl_at_external q <> None
    | Kresume q v => cl_at_external q <> None /\ v = Vundef
    | Kinit _ _ => Logic.True
    end.

Definition unique_Krun tp sch :=
  (lt 1 tp.(num_threads).(pos.n) -> forall i cnti q,
      @getThreadC i tp cnti = Krun q ->
      exists sch', sch = i :: sch').

Definition no_Krun tp :=
  forall i cnti q, @getThreadC i tp cnti <> Krun q.

Lemma no_Krun_unique_Krun tp sch : no_Krun tp -> unique_Krun tp sch.
Proof.
  intros H _ i cnti q E; destruct (H i cnti q E).
Qed.

Lemma containsThread_age_tp_to_eq tp n :
  containsThread (age_tp_to n tp) = containsThread tp.
Proof.
  destruct tp; reflexivity.
Qed.

Lemma no_Krun_age_tp_to n tp :
  no_Krun (age_tp_to n tp) = no_Krun tp.
Proof.
  destruct tp; reflexivity.
Qed.

Lemma unique_Krun_age_tp_to n tp sch :
  unique_Krun (age_tp_to n tp) sch <-> unique_Krun tp sch.
Proof.
  destruct tp; reflexivity.
Qed.

Lemma no_Krun_stable tp i cnti c' phi' :
  (forall q, c' <> Krun q) ->
  no_Krun tp ->
  no_Krun (@updThread i tp cnti c' phi').
Proof.
  intros notkrun H j cntj q.
  destruct (eq_dec i j).
  - subst.
    rewrite gssThreadCode.
    apply notkrun.
  - unshelve erewrite gsoThreadCode; auto.
Qed.

Lemma no_Krun_unique_Krun_updThread tp i sch cnti q phi' :
  no_Krun tp ->
  unique_Krun (@updThread i tp cnti (Krun q) phi') (i :: sch).
Proof.
  intros NO H j cntj q'.
  destruct (eq_dec i j).
  - subst.
    rewrite gssThreadCode.
    injection 1 as <-. eauto.
  - Set Printing Implicit.
    unshelve erewrite gsoThreadCode; auto.
    intros E; specialize (NO _ _ _ E). destruct NO.
Qed.

Lemma no_Krun_updLockSet tp loc ophi :
  no_Krun tp ->
  no_Krun (updLockSet tp loc ophi).
Proof.
  intros N; apply N.
Qed.

Lemma ssr_leP_inv i n : is_true (ssrnat.leq i n) -> i <= n.
Proof.
  pose proof @ssrnat.leP i n as H.
  intros E; rewrite E in H.
  inversion H; auto.
Qed.

Lemma different_threads_means_several_threads i j tp
      (cnti : containsThread tp i)
      (cntj : containsThread tp j) :
  i <> j -> 1 < pos.n (num_threads tp).
Proof.
  unfold containsThread in *.
  simpl in *.
  unfold tid in *.
  destruct tp as [n].
  simpl in *.
  remember (pos.n n) as k; clear Heqk n.
  apply ssr_leP_inv in cnti.
  apply ssr_leP_inv in cntj.
  omega.
Qed.

Lemma unique_Krun_no_Krun tp i sch cnti :
  unique_Krun tp (i :: sch) ->
  (forall q : code, @getThreadC i tp cnti <> Krun q) ->
  no_Krun tp.
Proof.
  intros U N j cntj q E.
  assert (i <> j). {
    intros <-.
    apply N with q.
    exact_eq E; do 2 f_equal.
    apply proof_irr.
  }
  unfold unique_Krun in *.
  assert_specialize U.
  now eapply (different_threads_means_several_threads i j); eauto.
  specialize (U _ _ _ E). destruct U. congruence.
Qed.

Lemma unique_Krun_no_Krun_updThread tp i sch cnti c' phi' :
  (forall q, c' <> Krun q) ->
  unique_Krun tp (i :: sch) ->
  no_Krun (@updThread i tp cnti c' phi').
Proof.
  intros notkrun uniq j cntj q.
  destruct (eq_dec i j) as [<-|N].
  - rewrite gssThreadCode.
    apply notkrun.
  - unshelve erewrite gsoThreadCode; auto.
    unfold unique_Krun in *.
    assert_specialize uniq.
    now eapply (different_threads_means_several_threads i j); eauto.
    intros E.
    specialize (uniq _ _ _ E).
    destruct uniq.
    congruence.
Qed.

Definition matchfunspec (ge : genviron) Gamma : forall Phi, Prop :=
  (ALL b : block,
    (ALL fs : funspec,
      seplog.func_at' fs (b, 0%Z) -->
      (EX id : ident,
        !! (ge id = Some b) && !! (Gamma ! id = Some fs))))%pred.

Definition lock_coherence' tp PHI m (mcompat : mem_compatible_with tp m PHI) :=
  lock_coherence
    (lset tp) PHI
    (restrPermMap
       (mem_compatible_locks_ltwritable
          (mem_compatible_forget mcompat))).

Inductive state_invariant {Z} (Jspec : juicy_ext_spec Z) Gamma (n : nat) : cm_state -> Prop :=
  | state_invariant_c
      (m : mem) (ge : genv) (sch : schedule) (tp : ThreadPool.t) (PHI : rmap)
      (lev : level PHI = n)
      (gamma : matchfunspec (filter_genv ge) Gamma PHI)
      (mcompat : mem_compatible_with tp m PHI)
      (lock_sparse : lock_sparsity (lset tp))
      (lock_coh : lock_coherence' tp PHI m mcompat)
      (safety : threads_safety Jspec m ge tp PHI mcompat n)
      (wellformed : threads_wellformed tp)
      (uniqkrun :  unique_Krun tp sch)
    : state_invariant Jspec Gamma n (m, ge, (sch, tp)).

Lemma mem_compatible_with_age {n tp m phi} :
  mem_compatible_with tp m phi ->
  mem_compatible_with (age_tp_to n tp) m (age_to n phi).
Proof.
  intros [J AC LW LJ JL]; constructor.
  - rewrite join_all_joinlist in *.
    rewrite maps_age_to.
    apply joinlist_age_to, J.
  - apply mem_cohere_age_to; easy.
  - apply lockSet_Writable_age; easy.
  - apply juicyLocks_in_lockSet_age. easy.
  - apply lockSet_in_juicyLocks_age. easy.
Qed.

(*  maybe we don't need this lemma, we just keep a tight relation n / level
Lemma state_invariant_S {Z} (Jspec : juicy_ext_spec Z) Gamma n m ge sch tp :
  state_invariant Jspec Gamma (S n) (m, ge, (sch, tp)) ->
  state_invariant Jspec Gamma n (m, ge, (sch, age_tp_to n tp)).
Proof.
  intros INV.
  inversion INV as [m0 ge0 sch0 tp0 PHI lev gam compat LC safety wellformed uniqkrun H0]; subst.
  apply state_invariant_c with (age_to n PHI) (mem_compatible_with_age compat); auto.
  - apply level_age_to. omega.
  - intros b fs phi necr fa.
    refine (gam b fs phi _ _).
    + apply necR_trans with (age_to n PHI); auto.
      apply age_to_necR.
    + auto.
  - intros loc.
    specialize (LC loc).
    rewrite lset_age_tp_to.
    rewrite AMap_find_map_option_map.
    destruct (AMap.find (elt:=option rmap) loc (lset tp)) as [[lockphi | ] | ].
    all: simpl option_map; cbv iota beta.
    all: exact_eq LC.
    all: f_equal.
    + f_equal.
      (* that's an awful lot of aging, probably we don't really need it in such a lemma *)
      
(*      unfold mem_compatible_with_age.
    match goal with
      |- match ?w with ?ASD end => idtac
    end.
  destruct compat as [J MC LW JL LJ].
  (* unshelve eapply state_invariant_c with (age_to n PHI) _; auto.
  - inversion mcompat as [A B C D E]; constructor.
    clear -lev A. *)
  intros i cnti ora; specialize (safety i cnti ora).
  destruct (ThreadPool.getThreadC cnti); auto; try apply safe_downward1, safety.
  intros c' E. apply safe_downward1, safety, E.
Qed.
 *)
Admitted.
*)

(* Schedule irrelevance of the invariant *)
Lemma state_invariant_sch_irr {Z} (Jspec : juicy_ext_spec Z) Gamma n m ge i sch sch' tp :
  state_invariant Jspec Gamma n (m, ge, (i :: sch, tp)) ->
  state_invariant Jspec Gamma n (m, ge, (i :: sch', tp)).
Proof.
  intros INV.
  inversion INV as [m0 ge0 sch0 tp0 PHI lev gam compat sparse lock_coh safety wellformed uniqkrun H0];
    subst m0 ge0 sch0 tp0.
  refine (state_invariant_c Jspec Gamma n m ge (i :: sch') tp PHI lev gam compat sparse lock_coh safety wellformed _).
  clear -uniqkrun.
  intros H i0 cnti q H0.
  destruct (uniqkrun H i0 cnti q H0) as [sch'' E].
  injection E as <- <-.
  eauto.
Qed.

(*+ Initial state *)

Section Initial_State.
  Variables
    (CS : compspecs) (V : varspecs) (G : funspecs)
    (ext_link : string -> ident) (prog : Clight.program)
    (all_safe : semax_prog.semax_prog (Concurrent_Oracular_Espec CS ext_link) prog V G)
    (init_mem_not_none : Genv.init_mem prog <> None).
  
  Definition Jspec := @OK_spec (Concurrent_Oracular_Espec CS ext_link).
  
  Definition init_m : { m | Genv.init_mem prog = Some m } :=
    match Genv.init_mem prog as y return (y <> None -> {m : mem | y = Some m}) with
    | Some m => fun _ => exist _ m eq_refl
    | None => fun H => (fun Heq => False_rect _ (H Heq)) eq_refl
    end init_mem_not_none.
  
  Definition initial_state (n : nat) (sch : schedule) : cm_state :=
    (proj1_sig init_m,
     globalenv prog,
     (sch,
      let spr := semax_prog_rule
                   (Concurrent_Oracular_Espec CS ext_link) V G prog
                   (proj1_sig init_m) all_safe (proj2_sig init_m) in
      let q : corestate := projT1 (projT2 spr) in
      let jm : juicy_mem := proj1_sig (snd (projT2 (projT2 spr)) n) in
      ThreadPool.mk
        (pos.mkPos (le_n 1))
        (* (fun _ => Kresume q Vundef) *)
        (fun _ => Krun q)
        (fun _ => m_phi jm)
        (addressFiniteMap.AMap.empty _)
     )
    ).
  
  Lemma personal_mem_of_same_jm tp jm (mc : mem_compatible tp (m_dry jm)) i (cnti : ThreadPool.containsThread tp i) :
    (ThreadPool.getThreadR cnti = m_phi jm) ->
    m_dry (personal_mem cnti mc) = m_dry jm.
  Proof.
  Admitted.
  
  Theorem initial_invariant n sch : state_invariant Jspec (make_tycontext_s G) n (initial_state n sch).
  Proof.
    unfold initial_state.
    destruct init_m as [m Hm]; simpl proj1_sig; simpl proj2_sig.
    set (spr := semax_prog_rule (Concurrent_Oracular_Espec CS ext_link) V G prog m all_safe Hm).
    set (q := projT1 (projT2 spr)).
    set (jm := proj1_sig (snd (projT2 (projT2 spr)) n)).
    match goal with |- _ _ _ (_, (_, ?TP)) => set (tp := TP) end.
    
    (*! compatibility of memories *)
    assert (compat : mem_compatible_with tp m (m_phi jm)).
    {
      constructor.
      + apply AllJuice with (m_phi jm) None.
        * change (proj1_sig (snd (projT2 (projT2 spr)) n)) with jm.
          unfold join_threads.
          unfold getThreadsR.
          
          match goal with |- _ ?l _ => replace l with (m_phi jm :: nil) end; swap 1 2. {
            simpl.
            set (a := m_phi jm).
            match goal with |- context [m_phi ?jm] => set (b := m_phi jm) end.
            replace b with a by reflexivity. clear. clearbody a.
            reflexivity.
            (* unfold fintype.ord_enum, eqtype.insub, seq.iota in *.
            simpl.
            destruct ssrbool.idP as [F|F]. reflexivity. exfalso. auto. *)
          }
          exists (core (m_phi jm)). {
            split.
            - apply join_comm.
              apply core_unit.
            - apply core_identity.
          }
        
        * reflexivity.
        * constructor.
      + destruct (snd (projT2 (projT2 spr))) as [jm' [D H]]; unfold jm; clear jm; simpl.
        subst m.
        apply mem_cohere'_juicy_mem.
      + intros b ofs.
        match goal with |- context [ssrbool.isSome ?x] => destruct x as [ phi | ] eqn:Ephi end; swap 1 2.
        { unfold is_true. simpl. congruence. } intros _.
        unfold tp in Ephi; simpl in Ephi.
        discriminate.
      + intros loc sh psh P z L.
        destruct (snd (projT2 (projT2 spr))) as [jm' [D [H [A NL]]]]; unfold jm in *; clear jm; simpl in L |- *.
        pose proof (NL loc) as NL'.
        rewrite L in NL'.
        edestruct NL as [lk ct].
        destruct lk; eauto.
      + hnf.
        simpl.
        intros ? F.
        inversion F.
    } (* end of mcompat *)
    
    assert (En : level (m_phi jm) = n). {
      unfold jm; clear.
      match goal with
        |- context [proj1_sig ?x] => destruct x as (jm' & jmm & lev & S & nolocks)
      end; simpl.
      rewrite level_juice_level_phi in *.
      auto.
    }
    
    apply state_invariant_c with (PHI := m_phi jm) (mcompat := compat); auto.
    
    - pose proof semax_prog_entry_point (Concurrent_Oracular_Espec CS ext_link) V G prog.
      unfold matchfunspec in *.
      simpl.
      intros b SPEC phi NECR FU.
      (* rewrite find_id_maketycontext_s. *)
      admit.
      (* we need to relate the [jm] given by [semax_prog_rule]  *)
    
    - (*! lock sparsity (no locks at first) *)
      intros l1 l2.
      rewrite threadPool.find_empty.
      tauto.
    
    - (*! lock coherence (no locks at first) *)
      intros lock.
      rewrite threadPool.find_empty.
      intros sh sh' z P; split; unfold jm;
      match goal with
        |- context [proj1_sig ?x] => destruct x as (jm' & jmm & lev & S & nolocks)
      end; simpl.
      + apply nolocks.
      + apply nolocks.
    
    - (*! safety of the only thread *)
      intros i cnti ora.
      destruct (ThreadPool.getThreadC cnti) as [c|c|c v|v1 v2] eqn:Ec; try discriminate; [].
      destruct i as [ | [ | i ]]. 2: now inversion cnti. 2:now inversion cnti.
      (* the initial juicy has got to be the same as the one given in initial_mem *)
      assert (Ejm: jm = jm_ cnti compat).
      {
        apply juicy_mem_ext; swap 1 2.
        - reflexivity.
        - unfold jm_.
          symmetry.
          unfold jm.
          destruct spr as (b' & q' & Hb & JS); simpl proj1_sig in *; simpl proj2_sig in *.
          destruct (JS n) as (jm' & jmm & lev & S & notlock); simpl projT1 in *; simpl projT2 in *.
          subst m.
          rewrite personal_mem_of_same_jm; eauto.
      }
      subst jm. rewrite <-Ejm.
      simpl in Ec. replace c with q in * by congruence.
      destruct spr as (b' & q' & Hb & JS); simpl proj1_sig in *; simpl proj2_sig in *.
      destruct (JS n) as (jm' & jmm & lev & Safe & notlock); simpl projT1 in *; simpl projT2 in *.
      subst q.
      simpl proj1_sig in *; simpl proj2_sig in *. subst n.
      apply (Safe ora).
    
    - (* well-formedness *)
      intros i cnti.
      constructor.
      
    - (* only one thread running *)
      intros F; exfalso. simpl in F. omega.
  Admitted.
  
End Initial_State.

Lemma join_resource_decay_S b phi1 phi1' phi2 phi2' phi3 :
  resource_decay b phi1 phi1' ->
  sepalg.join phi1 phi2 phi3 ->
  level phi1 = S (level phi1') ->
  age phi2 phi2' ->
  exists phi3',
    sepalg.join phi1' phi2' phi3' /\
    resource_decay b phi3 phi3'.
Proof.
  intros [_ rd] j lev a.
Admitted.

Unset Printing Implicit.

(* Constructive version of resource_decay (equivalent to the non-constructive version, see below) *)
Definition resource_decay_aux (nextb: block) (phi1 phi2: rmap) : Type :=
  prod (level phi1 >= level phi2)
  (forall l: address,
    
  ((fst l >= nextb)%positive -> phi1 @ l = NO Share.bot) *
  ( (resource_fmap (approx (level phi2)) (phi1 @ l) = (phi2 @ l))
    
  + { rsh : _ & { v : _ & { v' : _ |
       resource_fmap (approx (level phi2)) (phi1 @ l) = YES rsh pfullshare (VAL v) NoneP /\ 
       phi2 @ l = YES rsh pfullshare (VAL v') NoneP }}}
  
  + (fst l >= nextb)%positive * { v | phi2 @ l = YES Share.top pfullshare (VAL v) NoneP }
  
  + { v : _ & { pp : _ | phi1 @ l = YES Share.top pfullshare (VAL v) pp /\ phi2 @ l = NO Share.bot } })).

Ltac myintuition :=
  repeat
    match goal with
      H : _ \/ _  |- _ => destruct H
    | H : _ /\ _  |- _ => destruct H
    | H : prod _ _  |- _ => destruct H
    | H : sum _ _  |- _ => destruct H
    | H : sumbool _ _  |- _ => destruct H
    | H : sumor _ _  |- _ => destruct H
    | H : ex _  |- _ => destruct H
    | H : sig _  |- _ => destruct H
    | H : sigT _  |- _ => destruct H
    | H : sigT2 _  |- _ => destruct H
    end;
  discriminate || congruence || tauto || auto.

Ltac check_false P :=
  let F := fresh "false" in
  assert (F : P -> False) by (intro; myintuition);
  clear F.

Ltac sumsimpl :=
  match goal with
    |- sum ?A ?B => check_false A; right
  | |- sum ?A ?B => check_false B; left
  | |- sumor ?A ?B => check_false A; right
  | |- sumor ?A ?B => check_false B; left
  | |- sumbool ?A ?B => check_false A; right
  | |- sumbool ?A ?B => check_false B; left
  end.

Lemma resource_decay_aux_spec b phi1 phi2 :
  resource_decay b phi1 phi2 -> resource_decay_aux b phi1 phi2.
Proof.
  intros [lev rd]; split; [ apply lev | clear lev]; intros loc; specialize (rd loc).
  assert (D: {(fst loc >= b)%positive} + {(fst loc < b)%positive}) by (pose proof zlt; zify; eauto).
  split. apply rd. destruct rd as [nn rd].
  remember (phi1 @ loc) as r1.
  remember (phi2 @ loc) as r2.
  remember (level phi2) as n.
  clear phi1 phi2 Heqr1 Heqr2 Heqn.
  destruct r1 as [ sh1 | sh1 sh1' k1 pp1 | k1 pp1 ];
    destruct r2 as [ sh2 | sh2 sh2' k2 pp2 | k2 pp2 ];
    simpl in *.
  
  - sumsimpl. sumsimpl. sumsimpl. myintuition.
  
  - sumsimpl.
    sumsimpl.
    myintuition.
    destruct k2; split; eauto.
    now (exists m; myintuition).
    all: exfalso; myintuition.
  
  - sumsimpl.
    exfalso. myintuition.
  
  - sumsimpl.
    destruct (eq_dec sh1 Share.top).
    destruct (eq_dec sh1' pfullshare).
    destruct k1.
    destruct (eq_dec sh2 Share.bot).
    now subst; eauto.
    all: exfalso; myintuition.
  
  - sumsimpl.
    destruct D.
    + autospec nn. congruence.
    + sumsimpl.
      destruct (eq_dec sh1' pfullshare); subst.
      destruct (eq_dec sh2' pfullshare); subst.
      destruct (eq_dec k1 k2); try subst k2.
      now left; f_equal; myintuition.
      destruct k1, k2.
      right. exists sh1, m, m0. split; auto; f_equal; myintuition.
      all: try solve [exfalso; myintuition].
      sumsimpl. myintuition.
  
  - sumsimpl. exfalso; myintuition.
  
  - sumsimpl. exfalso; myintuition.
  
  - sumsimpl. sumsimpl. myintuition.
    destruct k2; split; eauto.
    now (exists m; myintuition).
    all: exfalso; myintuition.
  
  - sumsimpl. sumsimpl. sumsimpl. myintuition.
Qed.

Lemma resource_decay_aux_spec_inv b phi1 phi2 :
  resource_decay_aux b phi1 phi2 -> resource_decay b phi1 phi2.
Proof.
  intros [lev rd]; split; [ apply lev | clear lev]; intros loc; specialize (rd loc).
  myintuition; intuition eauto.
Qed.

Inductive res_join' : resource -> resource -> resource -> Type :=
    res_join'_NO1 : forall rsh1 rsh2 rsh3 : Share.t,
                   sepalg.join rsh1 rsh2 rsh3 ->
                   res_join' (NO rsh1) (NO rsh2) (NO rsh3)
  | res_join'_NO2 : forall (rsh1 rsh2 rsh3 : Share.t) (sh : pshare) 
                     (k : AV.kind) (p : preds),
                   sepalg.join rsh1 rsh2 rsh3 ->
                   res_join' (YES rsh1 sh k p) (NO rsh2) (YES rsh3 sh k p)
  | res_join'_NO3 : forall (rsh1 rsh2 rsh3 : Share.t) (sh : pshare) 
                     (k : AV.kind) (p : preds),
                   sepalg.join rsh1 rsh2 rsh3 ->
                   res_join' (NO rsh1) (YES rsh2 sh k p) (YES rsh3 sh k p)
  | res_join'_YES : forall (rsh1 rsh2 rsh3 : Share.t) (sh1 sh2 sh3 : pshare)
                     (k : AV.kind) (p : preds),
                   sepalg.join rsh1 rsh2 rsh3 ->
                   sepalg.join sh1 sh2 sh3 ->
                   res_join' (YES rsh1 sh1 k p) (YES rsh2 sh2 k p) (YES rsh3 sh3 k p)
  | res_join'_PURE : forall (k : AV.kind) (p : preds),
                    res_join' (PURE k p) (PURE k p) (PURE k p).

Lemma res_join'_spec r1 r2 r3 : res_join r1 r2 r3 -> res_join' r1 r2 r3.
Proof.
  intros J.
  destruct r1 as [sh1 | sh1 sh1' k1 pp1 | k1 pp1],
           r2 as [sh2 | sh2 sh2' k2 pp2 | k2 pp2],
           r3 as [sh3 | sh3 sh3' k3 pp3 | k3 pp3].
  all: try solve [ exfalso; inversion J ].
  all: try (assert (k1 = k3) by (inv J; auto); subst).
  all: try (assert (k2 = k3) by (inv J; auto); subst).
  all: try (assert (pp1 = pp3) by (inv J; auto); subst).
  all: try (assert (pp2 = pp3) by (inv J; auto); subst).
  all: try (assert (sh1' = sh3') by (inv J; auto); subst).
  all: try (assert (sh2' = sh3') by (inv J; auto); subst).
  all: constructor; inv J; auto.
Qed.

Lemma res_join'_spec_inv r1 r2 r3 : res_join' r1 r2 r3 -> res_join r1 r2 r3.
Proof.
  inversion 1; constructor; assumption.
Qed.

(* Constructive version of resource_decay (equivalent to the non-constructive version, see below) *)

Definition resource_decay_at (nextb: block) n (r1 r2 : resource) b := 
  ((b >= nextb)%positive -> r1 = NO Share.bot) /\
  (resource_fmap (approx (n)) (r1) = (r2) \/
  (exists rsh, exists v, exists v',
       resource_fmap (approx (n)) (r1) = YES rsh pfullshare (VAL v) NoneP /\ 
       r2 = YES rsh pfullshare (VAL v') NoneP)
  \/ ((b >= nextb)%positive /\ exists v, r2 = YES Share.top pfullshare (VAL v) NoneP)
  \/ (exists v, exists pp, r1 = YES Share.top pfullshare (VAL v) pp /\ r2 = NO Share.bot)).

(* @andrew ask if there is a name for this *)

Definition rmap_bound b phi :=
  (forall loc, (fst loc >= b)%positive -> phi @ loc = NO Share.bot).

(* @andrew those lemmas already somewhere? *)

Lemma join_bot_bot_eq sh :
  sepalg.join Share.bot Share.bot sh ->
  sh = Share.bot.
Proof.
  intros j.
  apply (join_eq j  (z' := Share.bot) (join_bot_eq Share.bot)).
Qed.

Lemma join_to_bot_l {sh1 sh2} :
  sepalg.join sh1 sh2 Share.bot ->
  sh1 = Share.bot.
Admitted.

Lemma join_to_bot_r {sh1 sh2} :
  sepalg.join sh1 sh2 Share.bot ->
  sh2 = Share.bot.
Admitted.

Lemma join_top_l {sh2 sh3} :
  sepalg.join Share.top sh2 sh3 ->
  sh2 = Share.bot.
Proof.
Admitted.
         
Lemma join_top {sh2 sh3} :
  sepalg.join Share.top sh2 sh3 ->
  sh3 = Share.top.
Proof.
Admitted.

Lemma join_pfullshare {sh2 sh3 : pshare} : ~sepalg.join pfullshare sh2 sh3.
Proof.
Admitted.

Lemma age_to_resource_at phi n loc : age_to n phi @ loc = resource_fmap (approx n) (phi @ loc).
Proof.
Admitted.

Lemma join_resource_decay b phi1 phi1' phi2 phi3 :
  rmap_bound b phi2 ->
  resource_decay b phi1 phi1' ->
  sepalg.join phi1 phi2 phi3 ->
  exists phi3',
    sepalg.join phi1' (age_to (level phi1') phi2) phi3' /\
    resource_decay b phi3 phi3'.
Proof.
  Unset Printing Implicit.
  intros bound rd; apply resource_decay_aux_spec in rd; revert rd.
  intros [lev rd] J.
  assert (lev12 : level phi1 = level phi2).
  { apply join_level in J; intuition congruence. }
  
  set (phi2' := age_to (level phi1') phi2).
  unfold resource_decay in *.
  
  assert (DESCR : forall loc,
             { r3 |
               sepalg.join (phi1' @ loc) (phi2' @ loc) r3 /\
               resource_decay_at b (level phi1') (phi3 @ loc) r3 (fst loc) /\
               resource_fmap (approx (level phi1')) r3 = r3
         }).
  {
    intros loc.
    specialize (rd loc).
    assert (D: {(fst loc >= b)%positive} + {(fst loc < b)%positive}) by (pose proof zlt; zify; eauto).
    apply resource_at_join with (loc := loc) in J.
    
    unfold phi2'; clear phi2'; rewrite age_to_resource_at.
    autospec bound.
    
    destruct rd as [nn [[[E1 | (rsh & v & v' & E1 & E1')] | (pos & v & E1') ] | (v & pp & E1 & E1')]].
    
    - exists ( resource_fmap (approx (level phi1')) (phi3 @ loc)).
      rewrite <-E1.
      split;[|split;[split|]].
      + inversion J; simpl; constructor; auto.
      + intros pos; autospec bound; autospec nn. rewrite bound in *; rewrite nn in *.
        inv J. f_equal. eapply join_bot_bot_eq; auto.
      + left. auto.
      + Lemma resource_fmap_approx_idempotent n r :
          resource_fmap (approx n) (resource_fmap (approx n) r) = resource_fmap (approx n) r.
        Proof.
          destruct r; simpl; f_equal.
          - destruct p0; simpl.
            rewrite <-compose_assoc.
            rewrite approx_oo_approx.
            reflexivity.
          - destruct p; simpl.
            rewrite <-compose_assoc.
            rewrite approx_oo_approx.
            reflexivity.
        Qed.
        apply resource_fmap_approx_idempotent.
    
    - rewrite E1'.
      apply res_join'_spec in J.
      inversion J; rewr (phi1 @ loc) in E1; simpl in *.
      all:try congruence.
      + injection E1; intros; subst.
        exists (YES rsh3 pfullshare (VAL v') NoneP).
        split;[|split;[split|]].
        * constructor; assumption.
        * intros pos; autospec bound; autospec nn. rewrite bound in *; rewrite nn in *.
          congruence.
        * right. left. simpl. exists rsh3, v, v'. split; congruence.
        * simpl. f_equal. unfold "oo"; simpl.
          unfold NoneP in *. simpl. f_equal. extensionality.
          apply approx_FF.
      + injection E1; intros; subst.
        rewr (phi1 @ loc) in J.
        apply res_join'_spec_inv in J.
        apply YES_join_full in J.
        exfalso. myintuition.
    
    - autospec nn.
      autospec bound.
      rewrite nn in *.
      rewrite bound in *.
      apply res_join'_spec in J.
      inv J; simpl.
      exists (phi1' @ loc).
      rewrite E1'.
      split;[|split;[split|]].
      + constructor. eauto.
      + intros _. f_equal.
        apply join_bot_bot_eq. auto.
      + right. right. left. eauto.
      + simpl. unfold NoneP in *. simpl. do 2 f_equal. extensionality.
        apply approx_FF.
    
    - rewrite E1 in J.
      exists (NO Share.bot).
      rewrite E1'.
      inv J.
      + simpl.
        split;[|split;[split|]].
        * constructor.
          cut (rsh2 = Share.bot).
          now intros ->; auto with *.
          revert RJ; clear.
          apply join_top_l.
        * intros pos; autospec bound; autospec nn. rewrite bound in *; rewrite nn in *.
          congruence.
        * right. right. right. exists v, pp. split; f_equal.
          revert RJ; clear.
          apply join_top.
        * reflexivity.
      + exfalso.
        eapply join_pfullshare.
        eauto.
  }
  
  destruct (make_rmap (fun loc => proj1_sig (DESCR loc))) with (n := level phi1') as (phi3' & lev3 & at3).
  {
    (* validity *)
    intros b' ofs; unfold "oo"; simpl.
    pose proof phi_valid phi1 as V1.
    pose proof phi_valid phi2 as V2.
    pose proof phi_valid phi3 as V3.
    admit. (* doable *)
  }
  {
    (* the right level of approximation *)
    unfold "oo".
    extensionality loc; simpl.
    destruct (DESCR loc) as (?&?&rd3&?); simpl; auto.
  }
  
  exists phi3'.
  split;[|split].
  - apply resource_at_join2; auto.
    + rewrite lev3.
      unfold phi2'.
      apply level_age_to.
      eauto with *.
    + intros loc.
      rewrite at3.
      destruct (DESCR loc) as (?&?&?); simpl; auto.
  - rewrite lev3.
    apply join_level in J.
    auto with *.
  - intros loc.
    rewrite at3.
    destruct (DESCR loc) as (?&?&rd3); simpl; auto.
    destruct rd3 as [[NN rd3] _].
    split; auto.
    destruct rd3 as [R|[R|[R|R]]].
    + left. exact_eq R; do 3 f_equal. auto.
    + right; left. exact_eq R.
      do 7 (f_equal; try extensionality).
      auto.
    + right; right; left. auto.
    + auto.
Admitted.

Lemma rmap_bound_join {b phi1 phi2 phi3} :
  sepalg.join phi1 phi2 phi3 ->
  rmap_bound b phi3 <-> (rmap_bound b phi1 /\ rmap_bound b phi2).
Proof.
  intros j; split.
  - intros B; split.
    + intros l p; specialize (B l p).
      apply resource_at_join with (loc := l) in j.
      rewrite B in j.
      inv j. f_equal. apply (join_to_bot_l RJ).
    + intros l p; specialize (B l p).
      apply resource_at_join with (loc := l) in j.
      rewrite B in j.
      inv j. f_equal. apply (join_to_bot_r RJ).
  - intros [B1 B2] l p.
    specialize (B1 l p).
    specialize (B2 l p).
    apply resource_at_join with (loc := l) in j.
    rewrite B1, B2 in j.
    inv j. f_equal. apply join_bot_bot_eq; auto.
Qed.

Lemma joinlist_resource_decay b phi1 phi1' l Phi :
  rmap_bound b Phi ->
  resource_decay b phi1 phi1' ->
  joinlist (phi1 :: l) Phi ->
  exists Phi',
    joinlist (phi1' :: (map (age_to (level phi1')) l)) Phi' /\
    resource_decay b Phi Phi'.
Proof.
  intros B rd (x & h & j).
  assert (Bx : rmap_bound b x). { apply (rmap_bound_join j) in B. intuition. }
  destruct (join_resource_decay _ _ _ _ _ Bx rd j) as (Phi' & j' & rd').
  exists Phi'; split; auto.
  exists (age_to (level phi1') x); split; auto.
  apply joinlist_age_to, h.
Qed.

Lemma join_all_resource_decay {tp m Phi} c' {phi' i} {cnti : ThreadPool.containsThread tp i}:
  resource_decay (Mem.nextblock m) (ThreadPool.getThreadR cnti) phi' /\
  level (getThreadR cnti) = S (level phi') ->
  join_all tp Phi ->
  exists Phi',
    join_all (@updThread i (age_tp_to (level phi') tp) (cnt_age' cnti) c' phi') Phi' /\
    resource_decay (Mem.nextblock m) Phi Phi' /\
    level Phi = S (level Phi').
Proof.
  do 2 rewrite join_all_joinlist.
Admitted.

Lemma mem_cohere_step c c' jm jm' Phi (X : rmap) ge :
  mem_cohere' (m_dry jm) Phi ->
  sepalg.join (m_phi jm) X Phi ->
  corestep (juicy_core_sem cl_core_sem) ge c jm c' jm' ->
  exists Phi',
    sepalg.join (m_phi jm') (age_to (level (m_phi jm')) X) Phi' /\
    mem_cohere' (m_dry jm') Phi'.
Proof.
  intros MC J C.
  destruct C as [step [RD L]].
  assert (Bx : rmap_bound (Mem.nextblock (m_dry jm)) X). admit.
  destruct (join_resource_decay _ _ _ _ _  Bx RD (* L *) J) as [Phi' [J' RD']].
  exists Phi'. split. apply J'.
  constructor.
  - intros sh rsh v loc pp AT.
    pose proof resource_at_join _ _ _ loc J as Jloc.
    pose proof resource_at_join _ _ _ loc J' as J'loc.
    rewrite AT in J'loc.
    inversion J'loc; subst.
    + (* all was in jm' *)
      destruct MC.
      (* specialize (cont_coh sh rsh v loc pp). *)
      admit.
    + (* all was in X *)
(*      rewrite <-H in Jloc.
      inversion Jloc; subst.
      * symmetry in H7.
        pose proof cont_coh MC _ H7.
        intuition.
        (* because the juice was NO, the dry hasn't changed *)
        admit.
      * (* same reasoning? *)
        admit.
    + (* joining of permissions, values don't change *)
      symmetry in H.
      destruct jm'.
      apply (JMcontents _ _ _ _ _ H).. *)
Admitted.

Lemma resource_decay_matchfunspec {b phi phi' g Gamma} :
  resource_decay b phi phi' ->
  matchfunspec g Gamma phi ->
  matchfunspec g Gamma phi'.
Proof.
  intros RD M.
  unfold matchfunspec in *.
  intros b0 fs psi' necr' FUN.
  specialize (M b0 fs phi ltac:(constructor 2)).
  apply (hereditary_necR necr').
  { clear.
    intros phi phi' A (id & hg & hgam); exists id; split; auto. }
  apply (anti_hereditary_necR necr') in FUN; swap 1 2.
  { intros x y a. apply anti_hereditary_func_at', a. }
  apply (resource_decay_func_at'_inv RD) in FUN.
  autospec M.
  destruct M as (id & Hg & HGamma).
  exists id; split; auto.
Qed.

(** About lock_coherence *)

Lemma resource_decay_lock_coherence {b phi phi' lset m} :
  resource_decay b phi phi' ->
  lockSet_block_bound lset b ->
  (forall l p, AMap.find l lset = Some (Some p) -> level p = level phi) ->
  lock_coherence lset phi m ->
  lock_coherence (AMap.map (Coqlib.option_map (age_to (level phi'))) lset) phi' m.
Proof.
  intros rd BOUND SAMELEV LC loc; pose proof rd as rd'; destruct rd' as [L RD].
  specialize (LC loc).
  specialize (RD loc).
  rewrite AMap_find_map_option_map.
  destruct (AMap.find loc lset)
    as [[unlockedphi | ] | ] eqn:Efind;
    simpl option_map; cbv iota beta; swap 1 3.
  - intros sh sh' z pp.
    destruct RD as [NN [R|[R|[[P [v R]]|R]]]].
    + split; intros E; rewrite E in *;
        destruct (phi @ loc); try destruct k; simpl in R; try discriminate;
          [ refine (proj1 (LC _ _ _ _) _); eauto
          | refine (proj2 (LC _ _ _ _) _); eauto ].
    + destruct R as (sh'' & v & v' & E & E'). split; congruence.
    + split; congruence.
    + destruct R as (sh'' & v & v' & R). split; congruence.
  
  - assert (fst loc < b)%positive.
    { apply BOUND.
      rewrite Efind.
      constructor. }
    destruct LC as (dry & sh & R & lk); split; auto.
    eapply resource_decay_LK_at in lk; eauto.
  
  - assert (fst loc < b)%positive.
    { apply BOUND.
      rewrite Efind.
      constructor. }
    destruct LC as (dry & sh & R & lk & sat); split; auto.
    exists sh, (approx (level phi') R); split.
    + eapply resource_decay_LK_at' in lk; eauto.
    + match goal with |- ?a \/ ?b => cut (~b -> a) end.
      { destruct (level phi'); auto. } intros Nz.
      split.
      * rewrite level_age_by.
        rewrite level_age_to.
        -- omega.
        -- apply SAMELEV in Efind.
           eauto with *.
      * destruct sat as [sat | ?]; [ | omega ].
        unfold age_to.
        rewrite age_by_age_by.
        rewrite plus_comm.
        rewrite <-age_by_age_by.
        apply age_by_ind.
        { destruct R as [p h]. apply h. }
        apply sat.
Qed.

Lemma lock_coherence_age_to lset Phi m n :
  lock_coherence lset Phi m ->
  lock_coherence (AMap.map (option_map (age_to n)) lset) Phi m.
Proof.
  intros C loc; specialize (C loc).
  rewrite AMap_find_map_option_map.
  destruct (AMap.find (elt:=option rmap) loc lset) as [[o|]|];
    simpl option_map;
    cbv iota beta.
  all:try solve [intuition].
  destruct C as [B C]; split; auto. clear B.
  destruct C as (sh & R & lk & sat).
  exists sh, R; split. eauto.
  destruct sat as [sat|?]; auto. left.
  unfold age_to.
  rewrite age_by_age_by, plus_comm, <-age_by_age_by.
  revert sat.
  apply age_by_ind.
  apply (proj2_sig R).
Qed.

Lemma lock_coherence_align lset Phi m b ofs :
  lock_coherence lset Phi m ->
  AMap.find (elt:=option rmap) (b, ofs) lset <> None ->
  (align_chunk Mint32 | ofs).
Proof.
  intros lock_coh find.
  specialize (lock_coh (b, ofs)).
  destruct (AMap.find (elt:=option rmap) (b, ofs) lset) as [[o|]|].
  + destruct lock_coh as [L _]; revert L; clear.
    unfold load_at; simpl.
    Transparent Mem.load.
    unfold Mem.load.
    if_tac. destruct H; auto. discriminate.
  + destruct lock_coh as [L _]; revert L; clear.
    unfold load_at; simpl.
    unfold Mem.load.
    if_tac. destruct H; auto. discriminate.
  + tauto.
Qed.

Lemma lset_valid_access m m_any tp Phi b ofs
  (compat : mem_compatible_with tp m Phi) :
  lock_coherence (lset tp) Phi m_any ->
  AMap.find (elt:=option rmap) (b, ofs) (lset tp) <> None ->
  Mem.valid_access (restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat))) Mint32 b ofs Writable.
Proof.
  intros C F.
  split.
  - eapply lset_range_perm; eauto.
  - eapply lock_coherence_align; eauto.
Qed.

Lemma load_restrPermMap m tp Phi b ofs m_any
  (compat : mem_compatible_with tp m Phi) :
  lock_coherence (lset tp) Phi m_any ->
  AMap.find (elt:=option rmap) (b, ofs) (lset tp) <> None ->
  Mem.load
    Mint32
    (restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat)))
    b ofs =
  Some (decode_val Mint32 (Mem.getN (size_chunk_nat Mint32) ofs (Mem.mem_contents m) !! b)).
Proof.
  intros lc e.
  unfold Mem.load in *.
  if_tac; auto.
  exfalso.
  apply H.
  eapply Mem.valid_access_implies.
  eapply lset_valid_access; eauto.
  constructor.
Qed.

Lemma PTree_xmap_ext (A B : Type) (f f' : positive -> A -> B) t :
  (forall a, f a = f' a) ->
  PTree.xmap f t = PTree.xmap f' t.
Proof.
  intros E.
  induction t as [ | t1 IH1 [a|] t2 IH2 ].
  - reflexivity.
  - simpl.
    extensionality p.
    rewrite IH1, IH2, E.
    reflexivity.
  - simpl.
    rewrite IH1, IH2.
    reflexivity.
Qed.

Lemma juicyRestrictCur_ext m phi phi'
      (coh : access_cohere' m phi)
      (coh' : access_cohere' m phi')
      (same : forall loc, perm_of_res (phi @ loc) = perm_of_res (phi' @ loc)) :
  Mem.mem_access (juicyRestrict coh) =
  Mem.mem_access (juicyRestrict coh').
Proof.
  unfold juicyRestrict in *.
  unfold restrPermMap in *; simpl.
  f_equal.
  unfold PTree.map in *.
  eapply equal_f.
  apply PTree_xmap_ext.
  intros b.
  extensionality f ofs k.
  destruct k; auto.
  unfold juice2Perm in *.
  unfold mapmap in *.
  simpl.
  unfold PTree.map in *.
  eapply equal_f.
  f_equal.
  f_equal.
  eapply equal_f.
  apply PTree_xmap_ext.
  intros.
  extensionality c ofs0.
  apply same.
Qed.

Lemma PTree_xmap_self A f (m : PTree.t A) i :
  (forall p a, m ! p = Some a -> f (PTree.prev_append i p) a = a) ->
  PTree.xmap f m i = m.
Proof.
  revert i.
  induction m; intros i E.
  - reflexivity.
  - simpl.
    f_equal.
    + apply IHm1.
      intros p a; specialize (E (xO p) a).
      apply E.
    + specialize (E xH).
      destruct o eqn:Eo; auto.
    + apply IHm2.
      intros p a; specialize (E (xI p) a).
      apply E.
Qed.

Lemma PTree_map_self (A : Type) (f : positive -> A -> A) t :
  (forall b a, t ! b = Some a -> f b a = a) ->
  PTree.map f t = t.
Proof.
  intros H.
  apply PTree_xmap_self, H.
Qed.

Lemma juicyRestrictCur_unchanged m phi 
      (coh : access_cohere' m phi)
      (pres : forall loc, perm_of_res (phi @ loc) = access_at m loc Cur) :
  Mem.mem_access (juicyRestrict coh) = Mem.mem_access m.
Proof.
  unfold juicyRestrict in *.
  unfold restrPermMap in *; simpl.
  unfold access_at in *.
  destruct (Mem.mem_access m) as (a, t) eqn:Eat.
  simpl.
  f_equal.
  - extensionality ofs k.
    destruct k. auto.
    pose proof Mem_canonical_useful m as H.
    rewrite Eat in H.
    auto.
  - apply PTree_xmap_self.
    intros b f E.
    extensionality ofs k.
    destruct k; auto.
    specialize (pres (b, ofs)).
    unfold "!!" in pres.
    simpl in pres.
    rewrite E in pres.
    rewrite <-pres.
    simpl.
    unfold juice2Perm in *.
    unfold mapmap in *.
    unfold "!!".
    simpl.
    rewrite Eat; simpl.
    rewrite PTree.gmap.
    rewrite PTree.gmap1.
    rewrite E.
    simpl.
    reflexivity.
Qed.

Lemma ZIndexed_index_surj p : { z : Z | ZIndexed.index z = p }.
Proof.
  destruct p.
  exists (Z.neg p); reflexivity.
  exists (Z.pos p); reflexivity.
  exists Z0; reflexivity.
Qed.

Lemma lock_coh_bound tp m Phi
      (compat : mem_compatible_with tp m Phi)
      (coh : lock_coherence' tp Phi m compat) :
  lockSet_block_bound (lset tp) (Mem.nextblock m).
Proof.
  intros loc find.
  specialize (coh loc).
  destruct (AMap.find (elt:=option rmap) loc (lset tp)) as [o|]; [ | inversion find ].
  match goal with |- (?a < ?b)%positive => assert (D : (a >= b \/ a < b)%positive) by (zify; omega) end.
  destruct D as [D|D]; auto. exfalso.
  assert (AT : exists (sh : Share.t) (R : pred rmap), (LK_at R sh loc) Phi). {
    destruct o.
    - destruct coh as [LOAD (sh' & R' & lk & sat)]; eauto.
    - destruct coh as [LOAD (sh' & R' & lk)]; eauto.
  }
  clear coh.
  destruct AT as (sh & R & AT).
  destruct compat.
  destruct all_cohere0.
  specialize (all_coh0 loc D).
  specialize (AT loc).
  destruct loc as (b, ofs).
  simpl in AT.
  if_tac in AT. 2:range_tac.
  if_tac in AT. 2:tauto.
  rewrite all_coh0 in AT.
  destruct AT.
  congruence.
Qed.

Lemma same_except_cur_jm_ tp m phi i cnti compat :
  same_except_cur m (m_dry (@jm_ tp m phi i cnti compat)).
Proof.
  repeat split.
  extensionality loc.
  apply juicyRestrictMax.
Qed.

Lemma resource_decay_join_identity b phi phi' e e' :
  resource_decay b phi phi' ->
  sepalg.joins phi e ->
  sepalg.joins phi' e' ->
  identity e ->
  identity e' ->
  e' = age_to (level phi') e.
Admitted.

Lemma core_necr_join_identity (phi phi' e e' : rmap) :
  necR (core phi) (core phi') ->
  sepalg.joins phi e ->
  sepalg.joins phi' e' ->
  identity e ->
  identity e' ->
  e' = age_to (level phi') e.
Admitted.

Lemma jsafeN_downward {Z} {Jspec : juicy_ext_spec Z} {ge n z c jm} :
  jsafeN Jspec ge (S n) z c jm ->
  jsafeN Jspec ge n z c jm.
Proof.
  apply safe_downward1.
Qed.

Lemma mem_cohere'_store m tp m' b ofs i Phi :
  forall Hcmpt : mem_compatible tp m,
    lockRes tp (b, Int.intval ofs) <> None ->
    Mem.store
      Mint32 (restrPermMap (mem_compatible_locks_ltwritable Hcmpt))
      b (Int.intval ofs) (Vint i) = Some m' ->
    mem_compatible_with tp m Phi (* redundant with Hcmpt, but easier *) ->
    mem_cohere' m' Phi.
Proof.
  intros Hcmpt lock Hstore compat.
  pose proof store_outside' _ _ _ _ _ _ Hstore as SO.
  destruct compat as [J MC LW JL LJ].
  destruct MC as [Co Ac Ma N].
  split.
  - intros sh sh' v (b', ofs') pp E.
    specialize (Co sh sh' v (b', ofs') pp E).
    destruct Co as [<- ->]. split; auto.
    destruct SO as (Co1 & A1 & N1).
    specialize (Co1 b' ofs').
    destruct Co1 as [In|Out].
    + exfalso (* because there is no lock at (b', ofs') *).
      specialize (LJ (b, Int.intval ofs)).
      cleanup.
      destruct (AMap.find (elt:=option rmap) (b, Int.intval ofs) (lset tp)).
      2:tauto.
      autospec LJ.
      destruct LJ as (sh1 & sh1' & pp & EPhi).
      destruct In as (<-, In).
      destruct (eq_dec ofs' (Int.intval ofs)).
      * subst ofs'.
        congruence.
      * pose (ii := (ofs' - Int.intval ofs)%Z).
        assert (Hii : (0 < ii < LKSIZE)%Z).
        { unfold ii; split. omega.
          unfold LKSIZE, LKCHUNK, align_chunk, size_chunk in *.
          omega. }
        pose proof rmap_valid_e1 Phi b (Int.intval ofs) _ _ Hii sh1' as H.
        assert_specialize H.
        { rewrite EPhi. reflexivity. }
        replace (Int.intval ofs + ii)%Z with ofs' in H by (unfold ii; omega).
        rewrite E in H. simpl in H. congruence.
        
    + rewrite <-Out.
      rewrite restrPermMap_contents.
      auto.
      
  - intros loc.
    replace (max_access_at m' loc)
    with (max_access_at
            (restrPermMap (mem_compatible_locks_ltwritable Hcmpt)) loc)
    ; swap 1 2.
    { unfold max_access_at in *.
      destruct SO as (_ & -> & _). reflexivity. }
    clear SO.
    rewrite restrPermMap_max.
    apply Ac.
    
  - cut (max_access_cohere (restrPermMap (mem_compatible_locks_ltwritable Hcmpt)) Phi).
    { unfold max_access_cohere in *.
      unfold max_access_at in *.
      destruct SO as (_ & <- & <-). auto. }
    intros loc; specialize (Ma loc).
    rewrite restrPermMap_max. auto.

  - unfold alloc_cohere in *.
    destruct SO as (_ & _ & <-). auto.
Qed.


Section Simulation.
  Variables
    (CS : compspecs)
    (ext_link : string -> ident)
    (ext_link_inj : forall s1 s2, ext_link s1 = ext_link s2 -> s1 = s2).

  Definition Jspec' := (@OK_spec (Concurrent_Oracular_Espec CS ext_link)).
  
  Lemma Jspec'_juicy_mem_equiv : ext_spec_stable juicy_mem_equiv (JE_spec _ Jspec').
  Proof.
    split; [ | easy ].
    intros e x b tl vl z m1 m2 E.
    
    unfold Jspec' in *.
    destruct e as [name sg | | | | | | | | | | | ].
    all: try (exfalso; simpl in x; do 2 (if_tac in x; [ discriminate | ]); apply x).
    
    (* dependent destruction *)
    revert x.
    
    simpl (ext_spec_pre _); simpl (ext_spec_type _); simpl (ext_spec_post _).
    unfold funspecOracle2pre, funspecOracle2post.
    unfold ext_spec_pre, ext_spec_post.
    destruct (oi_eq_dec (Some (ext_link "acquire")) (ef_id ext_link (EF_external name sg))) as [Eacquire | Nacquire].
    {
      (** * the case of acquire *)
      rewrite (proj2 E).
      exact (fun x y => y).
    }
    
    (* goal massaging for dependent destruction *)
    change (
      forall x :
          ext_spec_type
            (@OK_spec
               {| OK_spec :=
                   add_funspecsOracle_rec
                     ext_link (@OK_ty (ok_void_spec (list rmap))) (@OK_spec (ok_void_spec (list rmap)))
                     ((ext_link "release", release_oracular_spec) :: @nil (ident * funspecOracle Oracle)) |})
              (EF_external name sg),
        ext_spec_pre OK_spec (EF_external name sg) x b tl vl z m1 ->
        ext_spec_pre OK_spec (EF_external name sg) x b tl vl z m2
    ).
    
    simpl (ext_spec_pre _); simpl (ext_spec_type _); simpl (ext_spec_post _).
    unfold funspecOracle2pre, funspecOracle2post.
    unfold ext_spec_pre, ext_spec_post.
    destruct (oi_eq_dec (Some (ext_link "release")) (ef_id ext_link (EF_external name sg))) as [Erelease | Nrelease].
    {
      (** * the case of release *)
      rewrite (proj2 E).
      exact (fun x y => y).
    }
    
    (** * no more cases *)
    simpl.
    tauto.
  Qed.
  
  Lemma Jspec'_hered : ext_spec_stable age (JE_spec _ Jspec').
  Proof.
    split; [ | easy ].
    intros e x b tl vl z m1 m2 A.
    
    unfold Jspec' in *.
    destruct e as [name sg | | | | | | | | | | | ].
    all: try (exfalso; simpl in x; do 2 (if_tac in x; [ discriminate | ]); apply x).
    
    (* dependent destruction *)
    revert x.
    
    simpl (ext_spec_pre _); simpl (ext_spec_type _); simpl (ext_spec_post _).
    unfold funspecOracle2pre, funspecOracle2post.
    unfold ext_spec_pre, ext_spec_post.
    destruct (oi_eq_dec (Some (ext_link "acquire")) (ef_id ext_link (EF_external name sg))) as [Eacquire | Nacquire].
    {
      (** * the case of acquire *)
      intros x.
      intros (phi0 & phi1 & J & Pre & necr).
      apply age_jm_phi in A.
      destruct (age1_join2 (A := rmap) _ J A) as (phi0' & phi1' & J' & A0 & A1).
      exists phi0', phi1'; split; auto.
      split.
      - destruct x as (p, ((((ok, ora), v), sh), R)); simpl in Pre |- *.
        unfold canon.PROPx in *.
        unfold fold_right in *.
        unfold canon.LOCALx in *.
        destruct Pre as [? Pre].
        split; [ assumption | ].
        clear -A0 Pre.
        simpl in *.
        split; [ apply Pre | ].
        destruct Pre as [_ Pre].
        unfold canon.SEPx in *.
        simpl in *.
        revert Pre.
        match goal with |- app_pred ?a _ -> app_pred ?a _ => set (P := a) end.
        destruct P as [P Hered].
        apply Hered, A0.
      
      - econstructor 3.
        + apply necr.
        + constructor; auto.
    }
    
    (* goal massaging for dependent destruction *)
    change (
      forall x :
          ext_spec_type
            (@OK_spec
               {| OK_spec :=
                   add_funspecsOracle_rec
                     ext_link (@OK_ty (ok_void_spec (list rmap))) (@OK_spec (ok_void_spec (list rmap)))
                     ((ext_link "release", release_oracular_spec) :: @nil (ident * funspecOracle Oracle)) |})
              (EF_external name sg),
        ext_spec_pre OK_spec (EF_external name sg) x b tl vl z m1 ->
        ext_spec_pre OK_spec (EF_external name sg) x b tl vl z m2
    ).
    
    simpl (ext_spec_pre _); simpl (ext_spec_type _); simpl (ext_spec_post _).
    unfold funspecOracle2pre, funspecOracle2post.
    unfold ext_spec_pre, ext_spec_post.
    destruct (oi_eq_dec (Some (ext_link "release")) (ef_id ext_link (EF_external name sg))) as [Erelease | Nrelease].
    {
      (** * the case of release *)
      intros x.
      intros (phi0 & phi1 & J & Pre & necr).
      apply age_jm_phi in A.
      destruct (age1_join2 (A := rmap) _ J A) as (phi0' & phi1' & J' & A0 & A1).
      exists phi0', phi1'; split; auto.
      split.
      - destruct x as (p, (((ora, v), sh), R)); simpl in Pre |- *.
        unfold canon.PROPx in *.
        unfold fold_right in *.
        unfold canon.LOCALx in *.
        destruct Pre as [? Pre].
        split; [ assumption | ].
        clear -A0 Pre.
        simpl in *.
        split; [ apply Pre | ].
        destruct Pre as [_ Pre].
        unfold canon.SEPx in *.
        simpl in *.
        rewrite seplog.sepcon_emp in *.
        rewrite seplog.sepcon_emp in Pre.
        revert Pre.
        match goal with |- app_pred ?a _ -> app_pred ?a _ => set (P := a) end.
        destruct P as [P Hered].
        apply Hered, A0.
      
      - econstructor 3.
        + apply necr.
        + constructor; auto.
    }
    
    (** * no more cases *)
    simpl.
    tauto.
  Qed.
  
  Inductive state_step : cm_state -> cm_state -> Prop :=
  | state_step_empty_sched ge m jstate :
      state_step
        (m, ge, (nil, jstate))
        (m, ge, (nil, jstate))
  | state_step_c ge m m' sch sch' jstate jstate' :
      @JuicyMachine.machine_step ge sch nil jstate m sch' nil jstate' m' ->
      state_step
        (m, ge, (sch, jstate))
        (m', ge, (sch', jstate')).
  
  (* Preservation lemma for core steps *)  
  Lemma invariant_thread_step
        {Z} (Jspec : juicy_ext_spec Z) Gamma
        n m ge i sch tp Phi ci ci' jmi'
        (Stable : ext_spec_stable age Jspec)
        (Stable' : ext_spec_stable juicy_mem_equiv Jspec)
        (gam : matchfunspec (filter_genv ge) Gamma Phi)
        (compat : mem_compatible_with tp m Phi)
        (En : level Phi = S n)
        (lock_bound : lockSet_block_bound (ThreadPool.lset tp) (Mem.nextblock m))
        (sparse : lock_sparsity (lset tp))
        (lock_coh : lock_coherence' tp Phi m compat)
        (safety : threads_safety Jspec m ge tp Phi compat (S n))
        (wellformed : threads_wellformed tp)
        (unique : unique_Krun tp (i :: sch))
        (cnti : containsThread tp i)
        (stepi : corestep (juicy_core_sem cl_core_sem) ge ci (personal_mem cnti (mem_compatible_forget compat)) ci' jmi')
        (safei' : forall ora : Z, jsafeN Jspec ge n ora ci' jmi')
        (Eci : getThreadC cnti = Krun ci)
        (tp' := age_tp_to (level jmi') tp)
        (tp'' := @updThread i tp' (cnt_age' cnti) (Krun ci') (m_phi jmi') : ThreadPool.t)
        (cm' := (m_dry jmi', ge, (i :: sch, tp''))) :
    state_invariant Jspec Gamma n cm'.
  Proof.
    (** * Two steps : [x] -> [x'] -> [x'']
          1. we age [x] to get [x'], the level decreasing
          2. we update the thread to  get [x'']
     *)
    destruct compat as [J AC LW LJ JL] eqn:Ecompat. 
    rewrite <-Ecompat in *.
    pose proof J as J_; move J_ before J.
    rewrite join_all_joinlist in J_.
    pose proof J_ as J__.
    rewrite maps_getthread with (cnti := cnti) in J__.
    destruct J__ as (ext & Hext & Jext).
    assert (Eni : level (jm_ cnti compat) = S n). {
      rewrite <-En, level_juice_level_phi.
      eapply rmap_join_sub_eq_level.
      exists ext; auto.
    }
    
    (** * Getting new global rmap (Phi'') with smaller level [n] *)
    destruct (join_all_resource_decay (Krun ci') (proj2 stepi) J)
      as [Phi'' [J'' [RD L]]].
    rewrite join_all_joinlist in J''.
    assert (Eni'' : level (m_phi jmi') = n). {
      clear -stepi Eni.
      rewrite <-level_juice_level_phi.
      cut (S (level jmi') = S n); [ congruence | ].
      destruct stepi as [_ [_ <-]].
      apply Eni.
    }
    unfold LocksAndResources.res in *.
    pose proof eq_refl tp' as Etp'.
    unfold tp' at 2 in Etp'.
    move Etp' before tp'.
    rewrite level_juice_level_phi, Eni'' in Etp'.
    assert (En'' : level Phi'' = n). {
      rewrite <-Eni''.
      symmetry; apply rmap_join_sub_eq_level.
      rewrite maps_updthread in J''.
      destruct J'' as (r & _ & j).
      exists r; auto.
    }
    
    (** * First, age the whole machine *)
    pose proof J_ as J'.
    unshelve eapply @joinlist_age_to with (n := n) in J'.
    (* auto with *. (* TODO please report -- but hard to reproduce *) *)
    all: hnf.
    all: [> refine ag_rmap |  | refine Age_rmap | refine Perm_rmap ].
    
    (** * Then relate this machine with the new one through the remaining maps *)
    rewrite (maps_getthread i tp cnti) in J'.
    rewrite maps_updthread in J''.
    pose proof J' as J'_. destruct J'_ as (ext' & Hext' & Jext').
    rewrite maps_age_to, all_but_map in J''.
    pose proof J'' as J''_. destruct J''_ as (ext'' & Hext'' & Jext'').
    rewrite Eni'' in *.
    assert (Eext'' : ext'' = age_to n ext). {
      destruct (coqlib3.nil_or_non_nil (map (age_to n) (all_but i (maps tp)))) as [N|N]; swap 1 2.
      - (* Uniqueness of [ext] : when the rest is not empty *)
        eapply @joinlist_age_to with (n := n) in Hext.
        all: [> | now apply Age_rmap | now apply Perm_rmap ].
        unshelve eapply (joinlist_inj _ _ _ _ Hext'' Hext).
        apply N.
      - (* when the list is empty, we know that ext (and hence [age_to
        .. ext]) and ext' are identity, and they join with something
        that have the same PURE *)
        rewrite N in Hext''. simpl in Hext''.
        rewrite <-Eni''.
        eapply resource_decay_join_identity.
        + apply (proj2 stepi).
        + exists Phi. apply Jext.
        + exists Phi''. apply Jext''.
        + change (joinlist nil ext). exact_eq Hext. f_equal.
          revert N.
          destruct (maps tp) as [|? [|]]; destruct i; simpl; congruence || auto.
        + change (joinlist nil ext''). apply Hext''.
    }
    subst ext''.
    
    assert (compat_ : mem_compatible_with tp (m_dry (jm_ cnti compat)) Phi).
    { apply mem_compatible_with_same_except_cur with (m := m); auto.
      apply same_except_cur_jm_. }
    
    assert (compat' : mem_compatible_with tp' (m_dry (jm_ cnti compat)) (age_to n Phi)).
    { unfold tp'.
      rewrite level_juice_level_phi, Eni''.
      apply mem_compatible_with_age. auto. }
    
    assert (compat'' : mem_compatible_with tp'' (m_dry jmi') Phi'').
    {
      unfold tp''.
      constructor.
      
      - (* join_all (proved in lemma) *)
        rewrite join_all_joinlist.
        rewrite maps_updthread.
        unfold tp'. rewrite maps_age_to, all_but_map.
        exact_eq J''; repeat f_equal.
        auto.
      
      - (* cohere *)
        pose proof compat_ as c. destruct c as [_ MC _ _ _].
        destruct (mem_cohere_step
             ci ci' (jm_ cnti compat) jmi'
             Phi ext ge MC Jext stepi) as (Phi''_ & J''_ & MC''_).
        exact_eq MC''_.
        f_equal.
        rewrite Eni'' in J''_.
        eapply join_eq; eauto.
      
      - (* lockSet_Writable *)
        simpl.
        clear -LW stepi lock_coh lock_bound compat_.
        destruct stepi as [step _]. fold (jm_ cnti compat) in step.
        intros b ofs IN.
        unfold tp' in IN.
        rewrite lset_age_tp_to in IN.
        rewrite isSome_find_map in IN.
        specialize (LW b ofs IN).
        intros ofs0 interval.
        
        (* the juicy memory doesn't help much because we care about Max
        here. There are several cases were no permission change, the
        only cases where they do are:
        (1) call_internal (alloc_variables m -> m1)
        (2) return (free_list m -> m')
        in the end, (1) cannot hurt because there is already
        something, but maybe things have returned?
         *)
        
        set (mi := m_dry (jm_ cnti compat)).
        fold mi in step.
        (* state that the Cur [Nonempty] using the juice and the
             fact that this is a lock *)
        assert (CurN : (Mem.mem_access mi) !! b ofs0 Cur = Some Nonempty
                       \/ (Mem.mem_access mi) !! b ofs0 Cur = None).
        {
          pose proof juicyRestrictCurEq as H.
          unfold access_at in H.
          replace b with (fst (b, ofs0)) by reflexivity.
          replace ofs0 with (snd (b, ofs0)) by reflexivity.
          unfold mi.
          destruct compat_ as [_ MC _ _ _].
          destruct MC as [_ AC _ _].
          unfold jm_, personal_mem, personal_mem'; simpl m_dry.
          rewrite (H _ _  _ (b, ofs0)).
          cut (Mem.perm_order'' (Some Nonempty) (perm_of_res (ThreadPool.getThreadR cnti @ (b, ofs0)))). {
            destruct (perm_of_res (ThreadPool.getThreadR cnti @ (b,ofs0))) as [[]|]; simpl.
            all:intros po; inversion po; subst; eauto.
          }
          clear -compat IN interval lock_coh lock_bound.
          apply po_trans with (perm_of_res (Phi @ (b, ofs0))).
          - destruct compat.
            specialize (lock_coh (b, ofs)).
            assert (lk : exists (sh : Share.t) (R : pred rmap), (LK_at R sh (b, ofs)) Phi). {
              destruct (AMap.find (elt:=option rmap) (b, ofs) (ThreadPool.lset tp)) as [[lockphi|]|].
              - destruct lock_coh as [_ [sh [R [lk _]]]].
                now eexists _, _; apply lk.
              - destruct lock_coh as [_ [sh [R lk]]].
                now eexists _, _; apply lk.
              - discriminate.
            }
            destruct lk as (sh & R & lk).
            specialize (lk (b, ofs0)). simpl in lk.
            assert (adr_range (b, ofs) lock_size (b, ofs0))
              by apply interval_adr_range, interval.
            if_tac in lk; [ | tauto ].
            if_tac in lk.
            + injection H1 as <-.
              destruct lk as [p ->].
              simpl.
              constructor.
            + destruct lk as [p ->].
              simpl.
              constructor.
          - cut (join_sub (ThreadPool.getThreadR cnti @ (b, ofs0)) (Phi @ (b, ofs0))).
            + apply po_join_sub.
            + apply resource_at_join_sub.
              eapply compatible_threadRes_sub.
              apply compat.
        }
        
        apply cl_step_decay in step.
        pose proof step b ofs0 as D.
        assert (Emi: (Mem.mem_access mi) !! b ofs0 Max = (Mem.mem_access m) !! b ofs0 Max).
        {
          pose proof juicyRestrictMax (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti)) (b, ofs0).
          unfold max_access_at, access_at in *.
          simpl fst in H; simpl snd in H.
          rewrite H.
          reflexivity.
        }
        
        destruct (Maps.PMap.get b (Mem.mem_access m) ofs0 Max)
          as [ [ | | | ] | ] eqn:Emax;
          try solve [inversion LW].
        + (* Max = Freeable *)
          
          (* concluding using [decay] *)
          revert step CurN.
          clearbody mi.
          generalize (m_dry jmi'); intros mi'.
          clear -Emi. intros D [NE|NE].
          * replace ((Mem.mem_access mi') !! b ofs0 Max) with (Some Freeable). now constructor.
            symmetry.
            destruct (D b ofs0) as [A B].
            destruct (valid_block_dec mi b) as [v|n].
            -- autospec B.
               destruct B as [B|B].
               ++ destruct (B Cur). congruence.
               ++ specialize (B Max). congruence.
            -- pose proof Mem.nextblock_noaccess mi b ofs0 Max n.
               congruence.
          * replace ((Mem.mem_access mi') !! b ofs0 Max) with (Some Freeable). now constructor.
            symmetry.
            destruct (D b ofs0) as [A B].
            destruct (valid_block_dec mi b) as [v|n].
            -- autospec B.
               destruct B as [B|B].
               ++ destruct (B Cur); congruence.
               ++ specialize (B Max). congruence.
            -- pose proof Mem.nextblock_noaccess mi b ofs0 Max n.
               congruence.
        
        + (* Max = writable : must be writable after, because unchanged using "decay" *)
          assert (Same: (Mem.mem_access m) !! b ofs0 Max = (Mem.mem_access mi) !! b ofs0 Max) by congruence.
          revert step Emi Same.
          generalize (m_dry jmi').
          generalize (juicyRestrict (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti))).
          clear.
          intros m0 m1 D Emi Same.
          match goal with |- _ ?a ?b => cut (a = b) end.
          { intros ->; apply po_refl. }
          specialize (D b ofs0).
          destruct D as [A B].
          destruct (valid_block_dec mi b) as [v|n].
          * autospec B.
            destruct B as [B|B].
            -- destruct (B Max); congruence.
            -- specialize (B Max). congruence.
          * pose proof Mem.nextblock_noaccess m b ofs0 Max n.
            congruence.
        
        + (* Max = Readable : impossible because Max >= Writable  *)
          autospec LW.
          autospec LW.
          rewrite Emax in LW.
          inversion LW.
        
        + (* Max = Nonempty : impossible because Max >= Writable  *)
          autospec LW.
          autospec LW.
          rewrite Emax in LW.
          inversion LW.
        
        + (* Max = none : impossible because Max >= Writable  *)
          autospec LW.
          autospec LW.
          rewrite Emax in LW.
          inversion LW.
      
      - (* juicyLocks_in_lockSet *)
        eapply same_locks_juicyLocks_in_lockSet.
        + eapply resource_decay_same_locks.
          apply RD.
        + simpl.
          clear -LJ.
          intros loc sh psh P z H.
          unfold tp'.
          rewrite lset_age_tp_to.
          rewrite isSome_find_map.
          eapply LJ; eauto.
        
      - (* lockSet_in_juicyLocks *)
        eapply resource_decay_lockSet_in_juicyLocks.
        + eassumption.
        + simpl.
          apply lockSet_Writable_lockSet_block_bound.
          clear -LW.
          intros b ofs.
          unfold tp'; rewrite lset_age_tp_to.
          rewrite isSome_find_map.
          apply LW.
        
        + clear -JL.
          unfold tp'.
          intros addr; simpl.
          unfold tp'; rewrite lset_age_tp_to.
          rewrite isSome_find_map.
          apply JL.
    }
    (* end of proving mem_compatible_with *)
    
    (* Now that mem_compatible_with is established, we move on to the
       invariant. Two important parts:

       1) lock coherence is maintained, because the thread step could
          not affect locks in either kinds of memories
       
       2) safety is maintained: for thread #i (who just took a step),
          safety of the new state follows from safety of the old
          state. For thread #j != #i, we need to prove that the new
          memory is [juicy_mem_equiv] to the old one, in the sense
          that wherever [Cur] was readable the values have not
          changed.
    *)
    
    apply state_invariant_c with (PHI := Phi'') (mcompat := compat''); auto.
    - (* matchfunspecs *)
      eapply resource_decay_matchfunspec; eauto.
    
    - (* lock coherence: own rmap has changed, but we prove it did not affect locks *)
      unfold tp''; simpl.
      unfold tp'; simpl.
      apply lock_sparsity_age_to. auto.
    
    - (* lock coherence: own rmap has changed, but we prove it did not affect locks *)
      unfold lock_coherence', tp''; simpl lset.

      (* replacing level (m_phi jmi') with level Phi' ... *)
      assert (level (m_phi jmi') = level Phi'') by congruence.
      cut (lock_coherence
            (AMap.map (option_map (age_to (level Phi''))) (lset tp)) Phi''
            (restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat'')))).
      { intros A; exact_eq A.
        f_equal. unfold tp'; rewrite lset_age_tp_to.
        f_equal. f_equal. f_equal. rewrite level_juice_level_phi; auto. }
      (* done replacing *)
      
      (* operations on the lset: nothing happened *)
      apply (resource_decay_lock_coherence RD).
      { auto. }
      { intros. eapply join_all_level_lset; eauto. }
      
      clear -lock_coh lock_bound stepi.
      
      (* what's important: lock values couldn't change during a corestep *)
      assert
        (SA' :
           forall loc,
             AMap.find (elt:=option rmap) loc (lset tp) <> None ->
             load_at (restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat))) loc =
             load_at (restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat''))) loc).
      {
        destruct stepi as [step RD].
        unfold cl_core_sem in *.
        simpl in step.
        pose proof cl_step_decay _ _ _ _ _ step as D.
        intros (b, ofs) islock.
        pose proof juicyRestrictMax (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti)) (b, ofs).
        pose proof juicyRestrictContents (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti)) (b, ofs).
        unfold load_at in *; simpl.
        set (W  := mem_compatible_locks_ltwritable (mem_compatible_forget compat )).
        set (W' := mem_compatible_locks_ltwritable (mem_compatible_forget compat'')).
        pose proof restrPermMap_Cur W as RW.
        pose proof restrPermMap_Cur W' as RW'.
        pose proof restrPermMap_contents W as CW.
        pose proof restrPermMap_contents W' as CW'.
        Transparent Mem.load.
        unfold Mem.load in *.
        destruct (Mem.valid_access_dec (restrPermMap W) Mint32 b ofs Readable) as [r|n]; swap 1 2.
        
        { (* can't be not readable *)
          destruct n.
          apply Mem.valid_access_implies with Writable.
          - eapply lset_valid_access; eauto.
          - constructor.
        }
        
        destruct (Mem.valid_access_dec (restrPermMap W') Mint32 b ofs Readable) as [r'|n']; swap 1 2.
        { (* can't be not readable *)
          destruct n'.
          split.
          - apply Mem.range_perm_implies with Writable.
            + eapply lset_range_perm; eauto.
              unfold tp''; simpl.
              unfold tp'; rewrite lset_age_tp_to.
              rewrite AMap_find_map_option_map.
              destruct (AMap.find (elt:=option rmap) (b, ofs) (lset tp)).
              * discriminate.
              * tauto.
            + constructor.
          - (* basic alignment *)
            eapply lock_coherence_align; eauto.
        }
        
        f_equal.
        f_equal.
        apply Mem.getN_exten.
        intros ofs0 interval.
        eapply equal_f with (b, ofs0) in CW.
        eapply equal_f with (b, ofs0) in CW'.
        unfold contents_at in CW, CW'.
        simpl fst in CW, CW'.
        simpl snd in CW, CW'.
        rewrite CW, CW'.
        pose proof cl_step_unchanged_on _ _ _ _ _ b ofs0 step as REW.
        rewrite <- REW.
        - reflexivity.
        - unfold Mem.valid_block in *.
          simpl.
          apply (lock_bound (b, ofs)).
          destruct (AMap.find (elt:=option rmap) (b, ofs) (lset tp)). reflexivity. tauto.
        - pose proof juicyRestrictCurEq (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti)) (b, ofs0) as h.
          unfold access_at in *.
          simpl fst in h; simpl snd in h.
          unfold Mem.perm in *.
          rewrite h.
          cut (Mem.perm_order'' (Some Nonempty) (perm_of_res (getThreadR cnti @ (b, ofs0)))).
          { destruct (perm_of_res (getThreadR cnti @ (b, ofs0))); intros A B.
            all: inversion A; subst; inversion B; subst. }
          apply po_trans with (perm_of_res (Phi @ (b, ofs0))); swap 1 2.
          + eapply po_join_sub.
            apply resource_at_join_sub.
            eapply compatible_threadRes_sub.
            apply compat.
          + clear -lock_coh islock interval.
            (* todo make lemma out of this *)
            specialize (lock_coh (b, ofs)).
            assert (lk : exists sh R, (LK_at R sh (b, ofs)) Phi). {
              destruct (AMap.find (elt:=option rmap) (b, ofs) (lset tp)) as [[|]|].
              - destruct lock_coh as [_ (? & ? & ? & ?)]; eauto.
              - destruct lock_coh as [_ (? & ? & ?)]; eauto.
              - tauto.
            }
            destruct lk as (R & sh & lk).
            specialize (lk (b, ofs0)).
            simpl in lk.
            assert (adr_range (b, ofs) lock_size (b, ofs0))
              by apply interval_adr_range, interval.
            if_tac in lk; [|tauto].
            if_tac in lk.
            * destruct lk as [pp ->]. simpl. constructor.
            * destruct lk as [pp ->]. simpl. constructor.
      }
      (* end of proof of: lock values couldn't change during a corestep *)
      
      unfold lock_coherence' in *.
      intros loc; specialize (lock_coh loc). specialize (SA' loc).
      destruct (AMap.find (elt:=option rmap) loc (lset tp)) as [[lockphi|]|].
      + destruct lock_coh as [COH ?]; split; [ | easy ].
        rewrite <-COH; rewrite SA'; auto.
        congruence.
      + destruct lock_coh as [COH ?]; split; [ | easy ].
        rewrite <-COH; rewrite SA'; auto.
        congruence.
      + easy.
    
    - (* safety *)
      intros j cntj ora.
      destruct (eq_dec i j) as [e|n0].
      + subst j.
        replace (Machine.getThreadC cntj) with (Krun ci').
        * specialize (safei' ora).
          exact_eq safei'.
          f_equal.
          unfold jm_ in *.
          {
            apply juicy_mem_ext.
            - unfold personal_mem in *.
              simpl.
              match goal with |- _ = _ ?c => set (coh := c) end.
              apply mem_ext.
              
              + reflexivity.
              
              + rewrite juicyRestrictCur_unchanged.
                * reflexivity.
                * intros.
                  unfold "oo".
                  rewrite eqtype_refl.
                  unfold tp'; simpl.
                  unfold access_at in *.
                  destruct jmi'; simpl.
                  eauto.
              
              + reflexivity.
            
            - simpl.
              unfold "oo".
              rewrite eqtype_refl.
              auto.
          }
          
        * (* assert (REW: tp'' = (age_tp_to (level (m_phi jmi')) tp')) by reflexivity. *)
          (* clearbody tp''. *)
          subst tp''.
          rewrite gssThreadCode. auto.
      
      + unfold tp'' at 1.
        unfold tp' at 1.
        unshelve erewrite gsoThreadCode; auto.
        
        clear Ecompat Hext' Hext'' J'' Jext Jext' Hext RD J' LW LJ JL.
        
        (** * Bring other thread #j's memory up to current #i's level *)
        assert (cntj' : Machine.containsThread tp j). {
          unfold tp'', tp' in cntj.
          apply cntUpdate' in cntj.
          rewrite <-cnt_age in cntj.
          apply cntj.
        }
        pose (jmj' := age_to (level (m_phi jmi')) (@jm_ tp m Phi j cntj' compat)).
        
        (** * #j's memory is equivalent to the one it will be started in *)
        assert (E : juicy_mem_equiv  jmj' (jm_ cntj compat'')). {
          split.
          - unfold jmj'.
            rewrite m_dry_age_to.
            unfold jm_.
            unfold tp'' in compat''.
            pose proof
                 jstep_preserves_mem_equiv_on_other_threads
                 m ge i j tp ci ci' jmi' n0
                 (mem_compatible_forget compat)
                 cnti cntj' stepi
                 (mem_compatible_forget compat'')
              as H.
            exact_eq H.
            repeat f_equal.
            apply proof_irr.
          
          - unfold jmj'.
            unfold jm_ in *.
            rewrite m_phi_age_to.
            change (age_to (level (m_phi jmi')) (getThreadR cntj')
                    = getThreadR cntj).
            unfold tp'', tp'.
            unshelve erewrite gsoThreadRes; auto.
            unshelve erewrite getThreadR_age. auto.
            reflexivity.
        }
        
        unshelve erewrite <-gtc_age; auto.
        pose proof safety _ cntj' ora as safej.
        
        (* factoring all Krun / Kblocked / Kresume / Kinit cases in this one assert *)
        assert (forall c, jsafeN Jspec ge (S n) ora c (jm_ cntj' compat) ->
                     jsafeN Jspec ge n ora c (jm_ cntj compat'')) as othersafe.
        {
          intros c s.
          apply jsafeN_downward in s.
          apply jsafeN_age_to with (l := n) in s; auto.
          refine (jsafeN_mem_equiv _ _ s); auto.
          exact_eq E; f_equal.
          unfold jmj'; f_equal. auto.
        }
  
        destruct (@getThreadC j tp cntj') as [c | c | c v | v v0]; solve [auto].
    
    - (* wellformedness *)
      intros j cntj.
      unfold tp'', tp'.
      destruct (eq_dec i j) as [ <- | ij].
      + unshelve erewrite gssThreadCode; auto.
      + unshelve erewrite gsoThreadCode; auto.
        specialize (wellformed j). clear -wellformed.
        assert_specialize wellformed by (destruct tp; auto).
        unshelve erewrite <-gtc_age; auto.
    
    - (* uniqueness *)
      intros notalone j cntj q Ecj.
      hnf in unique.
      assert_specialize unique by (destruct tp; apply notalone).
      specialize (unique j).
      destruct (eq_dec i j) as [ <- | ij].
      + apply unique with (cnti := cnti) (q := ci); eauto.
      + assert_specialize unique by (destruct tp; auto).
        apply unique with (q := q); eauto.
        exact_eq Ecj. f_equal.
        unfold tp'',  tp'.
        unshelve erewrite gsoThreadCode; auto.
        unshelve erewrite <-gtc_age; auto.
  Qed.
  
  Lemma restrPermMap_mem_contents p' m (Hlt: permMapLt p' (getMaxPerm m)): 
    Mem.mem_contents (restrPermMap Hlt) = Mem.mem_contents m.
  Proof.
    reflexivity.
  Qed.
  
  Lemma islock_valid_access tp m b ofs p
        (compat : mem_compatible tp m) :
    (4 | ofs) ->
    lockRes tp (b, ofs) <> None ->
    p <> Freeable ->
    Mem.valid_access
      (restrPermMap
         (mem_compatible_locks_ltwritable compat))
      Mint32 b ofs p.
  Proof.
    intros div islock NE.
    eapply Mem.valid_access_implies with (p1 := Writable).
    2:destruct p; constructor || tauto.
    pose proof lset_range_perm.
    do 6 autospec H.
    split; auto.
  Qed.
  
  Theorem progress Gamma n state :
    state_invariant Jspec' Gamma (S n) state ->
    exists state',
      state_step state state'.
  Proof.
    intros I.
    inversion I as [m ge sch tp Phi En gam compat sparse lock_coh safety wellformed unique E]. rewrite <-E in *.
    destruct sch as [ | i sch ].
    
    (* empty schedule: we loop in the same state *)
    {
      exists state. subst. constructor.
    }
    
    destruct (ssrnat.leq (S i) tp.(ThreadPool.num_threads).(pos.n)) eqn:Ei; swap 1 2.
    
    (* bad schedule *)
    {
      eexists.
      (* split. *)
      (* -  *)constructor.
        apply JuicyMachine.schedfail with i.
        + reflexivity.
        + unfold ThreadPool.containsThread.
          now rewrite Ei; auto.
        + constructor.
        + reflexivity.
    }
    
    (* the schedule selected one thread *)
    assert (cnti : ThreadPool.containsThread tp i) by apply Ei.
    remember (ThreadPool.getThreadC cnti) as ci eqn:Eci; symmetry in Eci.
    
    destruct ci as
        [ (* Krun *) ci
        | (* Kblocked *) ci
        | (* Kresume *) ci v
        | (* Kinit *) v1 v2 ].
    
    (* thread[i] is running *)
    {
      pose (jmi := personal_mem cnti (mem_compatible_forget compat)).
      (* pose (phii := m_phi jmi). *)
      (* pose (mi := m_dry jmi). *)
      
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      (* thread[i] is running and some internal step *)
      {
        (* get the next step of this particular thread (with safety for all oracles) *)
        assert (next: exists ci' jmi',
                   corestep (juicy_core_sem cl_core_sem) ge ci jmi ci' jmi'
                   /\ forall ora, jsafeN Jspec' ge n ora ci' jmi').
        {
          specialize (safety i cnti).
          pose proof (safety nil) as safei.
          rewrite Eci in *.
          inversion safei as [ | ? ? ? ? c' m' step safe H H2 H3 H4 | | ]; subst.
          2: now match goal with H : at_external _ _ = _ |- _ => inversion H end.
          2: now match goal with H : halted _ _ = _ |- _ => inversion H end.
          exists c', m'. split; [ apply step | ].
          revert step safety safe; clear.
          generalize (jm_ cnti compat).
          generalize (State ve te k).
          unfold jsafeN.
          intros c j step safety safe ora.
          eapply safe_corestep_forward.
          - apply juicy_core_sem_preserves_corestep_fun.
            apply semax_lemmas.cl_corestep_fun'.
          - apply step.
          - apply safety.
        }
        
        destruct next as (ci' & jmi' & stepi & safei').
        pose (tp' := age_tp_to (level jmi') tp).
        pose (tp'' := @ThreadPool.updThread i tp' (cnt_age' cnti) (Krun ci') (m_phi jmi')).
        pose (cm' := (m_dry jmi', ge, (i :: sch, tp''))).
        exists cm'.
        apply state_step_c; [].
        apply JuicyMachine.thread_step with
        (tid := i)
          (ev := nil)
          (Htid := cnti)
          (Hcmpt := mem_compatible_forget compat); [|]. reflexivity.
        eapply step_juicy; [ | | | | | ].
        + reflexivity.
        + now constructor.
        + exact Eci. 
        + destruct stepi as [stepi decay].
          split.
          * simpl.
            subst.
            unfold SEM.Sem in *.
            rewrite SEM.CLN_msem.
            apply stepi.
          * simpl.
            exact_eq decay.
            reflexivity.
        + reflexivity.
        + reflexivity.
      }
      (* end of internal step *)
      
      (* thread[i] is running and about to call an external: Krun (at_ex c) -> Kblocked c *)
      {
        eexists.
        (* taking the step *)
        constructor.
        eapply JuicyMachine.suspend_step.
        + reflexivity.
        + reflexivity.
        + eapply mem_compatible_forget; eauto.
        + econstructor.
          * eassumption.
          * unfold SEM.Sem in *.
            rewrite SEM.CLN_msem.
            reflexivity.
          * constructor.
          * reflexivity.
      } (* end of Krun (at_ex c) -> Kblocked c *)
    } (* end of Krun *)
    
    (* thread[i] is in Kblocked *)
    {
      (* goes to Kresume ci' according to the rules of syncStep  *)
      
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      (* internal step: impossible, because in state Kblocked *)
      {
        exfalso.
        pose proof (wellformed i cnti) as W.
        rewrite Eci in W.
        apply W.
        reflexivity.
      }
      (* back to external step *)
      
      (* paragraph below: ef has to be an EF_external *)
      assert (Hef : match ef with EF_external _ _ => Logic.True | _ => False end).
      {
        pose proof (safety i cnti nil) as safe_i.
        rewrite Eci in safe_i.
        inversion safe_i; subst; [ now inversion H0; inversion H | | now inversion H ].
        inversion H0; subst; [].
        match goal with x : ext_spec_type _ _  |- _ => clear -x end.
        now destruct e eqn:Ee; [ apply I | .. ];
          simpl in x;
          repeat match goal with
                   _ : context [ oi_eq_dec ?x ?y ] |- _ =>
                   destruct (oi_eq_dec x y); try discriminate; try tauto
                 end.
      }
      assert (Ex : exists name sig, ef = EF_external name sig) by (destruct ef; eauto; tauto).
      destruct Ex as (name & sg & ->); clear Hef.
      
      (* paragraph below: ef has to be an EF_external with one of those 5 names *)
      assert (which_primitive :
                Some (ext_link "acquire") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "release") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "makelock") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "freelock") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "spawn") = (ef_id ext_link (EF_external name sg))).
      {
        pose proof (safety i cnti nil) as safe_i.
        rewrite Eci in safe_i.
        inversion safe_i; subst; [ now inversion H0; inversion H | | now inversion H ].
        inversion H0; subst; [].
        match goal with H : ext_spec_type _ _  |- _ => clear -H end.
        simpl in *.
        repeat match goal with
                 _ : context [ oi_eq_dec ?x ?y ] |- _ =>
                 destruct (oi_eq_dec x y); try injection e; auto
               end.
        tauto.
      }
      
      (* Before going any further, one needs to provide the first
        rmap of the oracle.  Unfortunately, for that, we need to know
        whether we're in an "acquire" external call or not. In
        addition, in the case of an "acquire" we need to know the
        arguments of the function (address+mpred) so that we can
        provide the right rmap from the lock set.
        |
        Two solutions: either we use a dummy oracle to know those things (but
        ... we need the oracle before that (FIX the spec OR [A]), or we write
        it as a P\/~P and then we derive a contradiction (not sure we can do
        that). *)
      
      destruct which_primitive as
          [ H_acquire | [ H_release | [ H_makelock | [ H_freelock | H_spawn ] ] ] ].
      
      { (* the case of acquire *)
        
        (* using the safety to prepare the precondition *)
        pose proof (safety i cnti nil) as safei.
        rewrite Eci in safei.
        unfold jsafeN, juicy_safety.safeN in safei.
        inversion safei
          as [ | n0 z c m0 c' m' H0 H1 H H2 H3 H4
               | n0 z c m0 e sig0 args0 x at_ex Pre SafePost H H3 H4 H5
               | n0 z c m0 i0 H H0 H1 H2 H3 H4];
          [ now inversion H0; inversion H | subst | now inversion H ].
        subst.
        simpl in at_ex. injection at_ex as <- <- <- .
        hnf in x.
        revert x Pre SafePost.
        
        (* dependent destruction *)
        simpl (ext_spec_pre _); simpl (ext_spec_post _).
        unfold funspecOracle2pre, funspecOracle2post.
        unfold ext_spec_pre, ext_spec_post.
        Local Notation "{| 'JE_spec ... |}" := {| JE_spec := _; JE_pre_hered := _; JE_post_hered := _; JE_exit_hered := _ |}.
        destruct (oi_eq_dec (Some (ext_link "acquire")) (ef_id ext_link (EF_external name sg)))
          as [Eef | Eef];
          [ | now clear -Eef H_acquire; simpl in *; congruence ].
        
        intros (phix, ((((ok, oracle_x), vx), shx), Rx)) Pre. simpl in Pre.
        destruct Pre as (phi0 & phi1 & Join & Precond & HnecR).
        simpl (and _).
        intros Post.
        
        (* relate lset to val *)
        destruct Precond as [PREA [[PREB _] PREC]].
        hnf in PREB.
        assert (islock : exists b ofs, vx = Vptr b ofs /\ exists R, islock_pred R (phi0 @ (b, Int.unsigned ofs))). {
          unfold canon.SEPx in PREC.
          simpl in PREC.
          rewrite seplog.sepcon_emp in PREC.
          unfold lock_inv in PREC.
          destruct PREC as (b & ofs & Evx & lk).
          exists b, ofs. split. now apply Evx.
          specialize (lk (b, Int.unsigned ofs)).
          exists (approx (level phi0) (Interp Rx)).
          simpl in lk.
          if_tac in lk; swap 1 2. {
            exfalso.
            apply H.
            unfold adr_range in *.
            intuition.
            unfold res_predicates.lock_size.
            omega.
          }
          if_tac in lk; [ | tauto ].
          destruct lk as [p lk].
          rewrite lk.
          do 3 eexists.
          unfold compose.
          reflexivity.
        }
        
        assert (SUB : join_sub phi0 Phi). {
          apply join_sub_trans with  (ThreadPool.getThreadR cnti).
          - econstructor; eauto.
          - apply compatible_threadRes_sub; eauto.
            destruct compat; eauto.
        }
        destruct islock as [b [ofs [-> [R islock]]]].
        pose proof (resource_at_join_sub _ _ (b, Int.unsigned ofs) SUB) as SUB'.
        pose proof islock_pred_join_sub SUB' islock as isl.
        
        (* PLAN
           - DONE: integrate the oracle in the semax_conc definitions
           - DONE: sort out this dependent type problem
           - DONE: exploit jsafeN_ to figure out which possible cases
           - DONE: push the analysis through Krun/Kblocked/Kresume
           - DONE: figure a wait out of the ext_link problem (the LOCK
             should be a parameter of the whole thing)
           - DONE: change the lock_coherence invariants to talk about
             Mem.load instead of directly reading the values, since
             this will be abstracted
           - TODO: acquire-fail: still problems (see below)
           - DONE: acquire-success: the invariant guarantees that the
             rmap in the lockset satisfies the invariant.  We can give
             this rmap as a first step to the oracle.  We again have
             to recover the fact that all oracles after this step will
             be fine as well.
           - TODO: spawning: it introduces a new Kinit, change
             invariant accordingly
           - TODO release: this time, the jsafeN_ will explain how to
             split the current rmap.
         *)
        
          
        (* next step depends on status of lock: *)
        pose proof (lock_coh (b, Int.unsigned ofs)) as lock_coh'.
        destruct (AMap.find (elt:=option rmap) (b, Int.unsigned ofs) (ThreadPool.lset tp))
          as [[unlockedphi|]|] eqn:Efind;
          swap 1 3.
        (* inversion lock_coh' as [wetv dryv notlock H H1 H2 | R0 wetv isl' Elockset Ewet Edry | R0 phi wetv isl' SAT_R_Phi Elockset Ewet Edry]. *)
        
        - (* None: that cannot be: there is no lock at that address *)
          exfalso.
          destruct isl as [x [? [? EPhi]]].
          rewrite EPhi in lock_coh'.
          eapply (proj1 (lock_coh' _ _ _ _)).
          reflexivity.
        
        - (* Some None: lock is locked, so [acquire] fails. *)
          destruct lock_coh' as [LOAD (sh' & R' & lk)].
          destruct isl as [sh [psh [z Ewetv]]].
          rewrite Ewetv in *.
          
          (* rewrite Eat in Ewetv. *)
          specialize (lk (b, Int.unsigned ofs)).
          rewrite jam_true in lk; swap 1 2.
          { hnf. unfold lock_size in *; split; auto; omega. }
          rewrite jam_true in lk; swap 1 2. now auto.
          
          unfold canon.SEPx in PREC.
          unfold fold_right in PREC.
          rewrite seplog.sepcon_emp in PREC.
          unfold lock_inv in PREC.
          destruct PREC as (b0 & ofs0 & EQ & LKSPEC).
          injection EQ as <- <-.
          exists (m, ge, (sch, tp))(* ; split *).
          + apply state_step_c.
            apply JuicyMachine.sync_step with
            (Htid := cnti)
              (Hcmpt := mem_compatible_forget compat)
              (ev := Events.failacq (b, Int.intval (* replace with unsigned? *) ofs));
              [ reflexivity (* schedPeek *)
              | reflexivity (* schedSkip *)
              | ].
            
            (* factoring proofs out before the inversion/eapply *)
            specialize (LKSPEC (b, Int.unsigned ofs)).
            simpl in LKSPEC.
            if_tac in LKSPEC; swap 1 2.
            { destruct H.
              unfold lock_size; simpl.
              split. reflexivity. omega. }
            if_tac in LKSPEC; [ | congruence ].
            destruct LKSPEC as (p & E).
            pose proof (resource_at_join _ _ _ (b, Int.unsigned ofs) Join) as J.
            rewrite E in J.
            
            assert (Ename : name = "acquire"). {
              simpl in *.
              injection H_acquire as Ee.
              apply ext_link_inj in Ee; auto.
            }
            
            assert (Ez : z = LKSIZE). {
              admit.
            }
            
            assert (Ecall: Some (EF_external name sg, sig, args) =
                           Some (LOCK, UNLOCK_SIG, Vptr b ofs :: nil)). {
              repeat f_equal.
              auto.
              - admit.
              - admit.
                 (* design decision:
                    - we can make 'safety' imply wellformedness of this signature
                    - or we can add wellformed as an hypothesis of the program *)
                 (* see with andrew: should safety require signatures
                 to be exactly something?  Maybe it should be in
                 ext_spec_type, it'd be easy, maybe. *)
              - assert (L: length args = 1%nat) by admit.
                (* TODO discuss with andrew for where to add this requirement *)
                clear -PREB L.
                unfold expr.eval_id in PREB.
                unfold expr.force_val in PREB.
                match goal with H : context [Map.get ?a ?b] |- _ => destruct (Map.get a b) eqn:E end.
                subst v. 2: discriminate.
                pose  (gx := (filter_genv (symb2genv (Genv.genv_symb ge)))). fold gx in E.
                destruct args as [ | arg [ | ar args ]].
                + now inversion E.
                + inversion E. reflexivity.
                + inversion E. f_equal.
                  inversion L.
            }
            
            assert (Eae : at_external SEM.Sem (ExtCall (EF_external name sg) sig args lid ve te k) =
                    Some (LOCK, ef_sig LOCK, Vptr b ofs :: nil)). {
              simpl.
              unfold SEM.Sem in *.
              rewrite SEM.CLN_msem; simpl.
              repeat f_equal; congruence.
            }
            
            assert
            (Hload :
               Mem.load
                 Mint32
                 (@restrPermMap
                    (lockSet tp) m
                    (@mem_compatible_locks_ltwritable
                       tp m (@mem_compatible_forget tp m Phi compat)))
                 b (Int.intval ofs) =
               @Some val (Vint Int.zero)).
            {
              rewrite <-LOAD.
              unfold load_at.
              Transparent Mem.load.
              unfold Mem.load.
              unfold restrPermMap at 5.
              simpl.
              if_tac; if_tac; try reflexivity.
              all: exfalso; unfold Int.unsigned in *; tauto.
            }
            
            inversion J; subst.
            
            * eapply step_acqfail with (Hcompatible := mem_compatible_forget compat)
                                       (R := approx (level phi0) (Interp Rx)).
              all: try solve [ constructor | eassumption | reflexivity ];
                [ > idtac ].
              simpl.
              unfold Int.unsigned in *.
              rewrite <-H7.
              reflexivity.
            
            * eapply step_acqfail with (Hcompatible := mem_compatible_forget compat)
                                       (R := approx (level phi0) (Interp Rx)).
              all: try solve [ constructor | eassumption | reflexivity ];
                [ > idtac ].
              simpl.
              unfold Int.unsigned in *.
              rewrite <-H7.
              reflexivity.
        
        - (* acquire succeeds *)
          destruct isl as [sh [psh [z Ewetv]]].
          destruct lock_coh' as [LOAD (sh' & R' & lk & sat)].
          rewrite Ewetv in *.
          
          unfold canon.SEPx in PREC.
          unfold fold_right in PREC.
          rewrite seplog.sepcon_emp in PREC.
          unfold lock_inv in PREC.
          destruct PREC as (b0 & ofs0 & EQ & LKSPEC).
          injection EQ as <- <-.
          
          specialize (lk (b, Int.unsigned ofs)).
          rewrite jam_true in lk; swap 1 2.
          { hnf. unfold lock_size in *; split; auto; omega. }
          rewrite jam_true in lk; swap 1 2. now auto.
          destruct sat as [sat | sat]; [ | omega ].
          
          (* destruct isl' as [sh' [psh' [z' Eat]]]. *)
          (*
          rewrite Eat in Ewetv.
          injection Ewetv as -> -> -> Epr.
          apply inj_pair2 in Epr.
          assert (R0 = R). {
            assert (feq: forall A B (f g : A -> B), f = g -> forall x, f x = g x) by congruence.
            apply (feq _ _ _ _ Epr tt).
          }
          subst R0; clear Epr.
           *)
          
          (* changing value of lock *)
          Unset Printing Implicit.
          pose (m1 := restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat))).
          assert (Hm' : exists m', Mem.store Mint32 m1 b (Int.intval ofs) (Vint Int.zero) = Some m'). {
            Transparent Mem.store.
            unfold Mem.store in *.
            destruct (Mem.valid_access_dec m1 Mint32 b (Int.intval ofs) Writable) as [N|N].
            now eauto.
            exfalso.
            apply N; unfold m1; clear -Efind lock_coh.
            eapply lset_valid_access; eauto.
            unfold Int.unsigned in *.
            congruence.
          }
          destruct Hm' as (m', Hm').
          
          (* joinability condition provided by invariant : phi' will be the thread's new rmap  *)
          destruct (compatible_threadRes_lockRes_join (mem_compatible_forget compat) cnti _ Efind) as (phi', Jphi').
          
          (* somehow the new mem and the Phi has to be a juicy memory *)
          assert (Hjm' : exists jm', m_dry jm' = m' /\ m_phi jm' = phi'). {
            admit (* ask santiago if he can provide such coherence results on restrPermMap *).
            (*unshelve eexists.
            unshelve refine (mkJuicyMem m' phi' _ _ _ _).
            all: try (split; reflexivity).
             *)
          }
          destruct Hjm' as (jm', Hjm').
          
          (* necessary to know that we have indeed a lock *)
          assert (ex: exists sh0 psh0, phi0 @ (b, Int.intval ofs) = YES sh0 psh0 (LK LKSIZE) (pack_res_inv (approx (level phi0) (Interp Rx)))). {
            clear -LKSPEC.
            specialize (LKSPEC (b, Int.intval ofs)).
            simpl in LKSPEC.
            if_tac in LKSPEC. 2:range_tac.
            if_tac in LKSPEC. 2:tauto.
            destruct LKSPEC as (p, E).
            do 2 eexists.
            apply E.
          }
          destruct ex as (sh0 & psh0 & ex).
          pose proof (resource_at_join _ _ _ (b, Int.intval ofs) Join) as Join'.
          destruct (join_YES_l Join' ex) as (sh3 & sh3' & E3).
          
          eexists (m_dry jm', ge, (sch, _)).
          + (* taking the step *)
            apply state_step_c.
            apply JuicyMachine.sync_step
            with (ev := (Events.acquire (b, Int.intval ofs) None))
                   (tid := i)
                   (Htid := cnti)
                   (Hcmpt := mem_compatible_forget compat)
            ;
              [ reflexivity | reflexivity | ].
            eapply step_acquire
            with (R := approx (level phi0) (Interp Rx))
            (* with (sh := shx) *)
            .
            all: try match goal with |- _ = age_tp_to _ _ => reflexivity end.
            all: try match goal with |- _ = updLockSet _ _ _ => reflexivity end.
            all: try match goal with |- _ = updThread _ _ _ => reflexivity end.
            * now auto.
            * eassumption.
            * simpl.
              unfold SEM.Sem in *.
              rewrite SEM.CLN_msem.
              simpl.
              repeat f_equal; [ | | | ].
              -- simpl in H_acquire.
                 injection H_acquire as Ee.
                 apply ext_link_inj in Ee.
                 rewrite <-Ee.
                 reflexivity.
              -- admit (* same problem above *).
              -- admit (* same problem above *).
              -- admit (* same problem above *).
            * reflexivity.
            * unfold fold_right in *.
              rewrite E3.
              f_equal.
            * reflexivity.
            * apply LOAD.
            * unfold m1 in Hm'.
              replace (m_dry jm') with m' by intuition.
              apply Hm'.
            * apply Efind.
            * replace (m_phi jm') with phi' by intuition.
              apply Jphi'.
      }

      { (* the case of release *) admit. }
      
      { (* the case of makelock *) admit. }
      
      { (* the case of freelock *) admit. }
      
      { (* the case of spawn *) admit. }
    }
    (* end of Kblocked *)
    
    (* thread[i] is in Kresume *)
    {
      (* goes to Krun ci' with after_ex ci = ci'  *)
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      - (* contradiction: has to be an extcall *)
        specialize (wellformed i cnti).
        rewrite Eci in wellformed.
        simpl in wellformed.
        tauto.
      
      - (* extcall *)
        pose (ci':=
                match lid with
                | Some id => State ve (Maps.PTree.set id (Vint Int.zero) te) k
                | None => State ve te k
                end).
        exists (m, ge, (i :: sch, ThreadPool.updThreadC cnti (Krun ci')))(* ; split *).
        + (* taking the step Kresum->Krun *)
          constructor.
          apply JuicyMachine.resume_step with (tid := i) (Htid := cnti).
          * reflexivity.
          * eapply mem_compatible_forget. eauto.
          * unfold SEM.Sem in *.
            eapply JuicyMachine.ResumeThread with (c := ci) (c' := ci');
              try rewrite SEM.CLN_msem in *;
              simpl.
            -- subst.
               unfold SEM.Sem in *.
               rewrite SEM.CLN_msem in *; simpl.
               reflexivity.
            -- subst.
               unfold SEM.Sem in *.
               rewrite SEM.CLN_msem in *; simpl.
               destruct lid; reflexivity.
            -- rewrite Eci.
               subst ci.
               f_equal.
               specialize (wellformed i cnti).
               rewrite Eci in wellformed.
               simpl in wellformed.
               tauto.
            -- constructor.
            -- reflexivity.
    }
    (* end of Kresume *)
    
    (* thread[i] is in Kinit *)
    {
      eexists(* ; split *).
      - constructor.
        apply JuicyMachine.start_step with (tid := i) (Htid := cnti).
        + reflexivity.
        + eapply mem_compatible_forget. eauto.
        + eapply JuicyMachine.StartThread.
          * apply Eci.
          * simpl.
            (* WE SAID THAT THIS SHOULD NOT BE IN THE MACHINE? *) 
            (* Maybe this is impossible and I have to do all the spawn
               work by myself. *)
           admit.
          * constructor.
          * reflexivity.
    }
    (* end of Kinit *)
  Admitted.
  
  Ltac jmstep_inv :=
    match goal with
    | H : JuicyMachine.start_thread _ _ _ |- _ => inversion H
    | H : JuicyMachine.resume_thread _ _  |- _ => inversion H
    | H : threadStep _ _ _ _ _ _          |- _ => inversion H
    | H : JuicyMachine.suspend_thread _ _ |- _ => inversion H
    | H : syncStep _ _ _ _ _ _            |- _ => inversion H
    | H : threadHalted _                  |- _ => inversion H
    | H : JuicyMachine.schedfail _        |- _ => inversion H
    end; try subst.
  
  Ltac getThread_inv :=
    match goal with
    | [ H : @getThreadC ?i _ _ = _ ,
            H2 : @getThreadC ?i _ _ = _ |- _ ] =>
      pose proof (getThreadC_fun _ _ _ _ _ _ H H2)
    | [ H : @getThreadR ?i _ _ = _ ,
            H2 : @getThreadR ?i _ _ = _ |- _ ] =>
      pose proof (getThreadR_fun _ _ _ _ _ _ H H2)
    end.
  
  Lemma Ejuicy_sem : juicy_sem = juicy_core_sem cl_core_sem.
  Proof.
    unfold juicy_sem; simpl.
    f_equal.
    unfold SEM.Sem, SEM.CLN_evsem.
    rewrite SEM.CLN_msem.
    reflexivity.
  Qed.
  
  Theorem preservation Gamma n state state' :
    state_step state state' ->
    state_invariant Jspec' Gamma (S n) state ->
    state_invariant Jspec' Gamma n state' \/
    state_invariant Jspec' Gamma (S n) state'.
  Proof.
    intros STEP.
    inversion STEP as [ | ge m m' sch sch' tp tp' jmstep E E']. now auto.
    (* apply state_invariant_S *)
    subst state state'; clear STEP.
    intros INV.
    inversion INV as [m0 ge0 sch0 tp0 Phi lev gam compat sparse lock_coh safety wellformed unique E].
    subst m0 ge0 sch0 tp0.
    
    destruct sch as [ | i sch ].
    
    (* empty schedule: we loop in the same state *)
    {
      inversion jmstep; subst; try inversion HschedN.
      (* PRESERVATION :
      subst; split.
      - constructor.
      - apply state_invariant_c with (PHI := Phi) (mcompat := compat); auto; [].
        intros i cnti ora. simpl.
        specialize (safety i cnti ora); simpl in safety.
        destruct (ThreadPool.getThreadC cnti); auto.
        all: eapply safe_downward1; intuition.
       *)
    }
    
    destruct (ssrnat.leq (S i) tp.(ThreadPool.num_threads).(pos.n)) eqn:Ei; swap 1 2.
    
    (* bad schedule *)
    {
      inversion jmstep; subst; try inversion HschedN; subst tid;
        unfold ThreadPool.containsThread, is_true in *;
        try congruence.
      simpl.
      
      assert (i :: sch <> sch) by (clear; induction sch; congruence).
      inversion jmstep; subst; simpl in *; try tauto;
        unfold ThreadPool.containsThread, is_true in *;
        try congruence.
      right. (* not consuming step level *)
      apply state_invariant_c with (PHI := Phi) (mcompat := compat); auto.
      (*
      + intros i0 cnti0 ora.
        specialize (safety i0 cnti0 ora); simpl in safety.
        eassert.
        * eapply safety; eauto.
        * destruct (ThreadPool.getThreadC cnti0) as [c|c|c v|v1 v2] eqn:Ec; auto;
            intros Safe; try split; try eapply safe_downward1, Safe.
          intros c' E. eapply safe_downward1, Safe, E.
      *)
      + (* invariant about "only one Krun and it is scheduled": the
          bad schedule case is not possible *)
        intros H0 i0 cnti q H1.
        exfalso.
        specialize (unique H0 i0 cnti q H1).
        destruct unique as [sch' unique]; injection unique as <- <- .
        congruence.
    }
    
    (* the schedule selected one thread *)
    assert (cnti : ThreadPool.containsThread tp i) by apply Ei.
    remember (ThreadPool.getThreadC cnti) as ci eqn:Eci; symmetry in Eci.
    (* remember (ThreadPool.getThreadR cnti) as phi_i eqn:Ephi_i; symmetry in Ephi_i. *)
    
    destruct ci as
        [ (* Krun *) ci
        | (* Kblocked *) ci
        | (* Kresume *) ci v
        | (* Kinit *) v1 v2 ].
    
    (* thread[i] is running *)
    {
      pose (jmi := personal_mem cnti (mem_compatible_forget compat)).
      (* pose (phii := m_phi jmi). *)
      (* pose (mi := m_dry jmi). *)
      
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      (* thread[i] is running and some internal step *)
      {
        (* get the next step of this particular thread (with safety for all oracles) *)
        assert (next: exists ci' jmi',
                   corestep (juicy_core_sem cl_core_sem) ge ci jmi ci' jmi'
                   /\ forall ora, jsafeN Jspec' ge n ora ci' jmi').
        {
          specialize (safety i cnti).
          pose proof (safety nil) as safei.
          rewrite Eci in *.
          inversion safei as [ | ? ? ? ? c' m'' step safe H H2 H3 H4 | | ]; subst.
          2: now match goal with H : at_external _ _ = _ |- _ => inversion H end.
          2: now match goal with H : halted _ _ = _ |- _ => inversion H end.
          exists c', m''. split; [ apply step | ].
          revert step safety safe; clear.
          generalize (jm_ cnti compat).
          generalize (State ve te k).
          unfold jsafeN.
          intros c j step safety safe ora.
          eapply safe_corestep_forward.
          - apply juicy_core_sem_preserves_corestep_fun.
            apply semax_lemmas.cl_corestep_fun'.
          - apply step.
          - apply safety.
        }
        
        destruct next as (ci' & jmi' & stepi & safei').
        pose (tp'' := @ThreadPool.updThread i tp cnti (Krun ci') (m_phi jmi')).
        pose (tp''' := age_tp_to (level jmi') tp').
        pose (cm' := (m_dry jmi', ge, (i :: sch, tp'''))).
        
        (* now, the step that has been taken in jmstep must correspond
        to this cm' *)
        inversion jmstep; subst; try inversion HschedN; subst tid;
          unfold ThreadPool.containsThread, is_true in *;
          try congruence.
        
        - (* not in Kinit *)
          jmstep_inv. getThread_inv. congruence.
        
        - (* not in Kresume *)
          jmstep_inv. getThread_inv. congruence.
        
        - (* here is the important part, the corestep *)
          jmstep_inv.
          assert (En : level Phi = S n) by auto. (* will be in invariant *)
          left. (* consuming one step of level *)
          eapply invariant_thread_step; eauto.
          + apply Jspec'_hered.
          + apply Jspec'_juicy_mem_equiv.
          + eapply lock_coh_bound; eauto.
          + exact_eq Hcorestep.
            rewrite Ejuicy_sem.
            do 2 f_equal.
            apply proof_irr.
          + rewrite Ejuicy_sem in *.
            getThread_inv.
            injection H as <-.
            unfold jmi in stepi.
            exact_eq safei'.
            extensionality ora.
            cut ((ci', jmi') = (c', jm')). now intros H; injection H as -> ->; auto.
            eapply juicy_core_sem_preserves_corestep_fun; eauto.
            * apply semax_lemmas.cl_corestep_fun'.
            * exact_eq Hcorestep.
              do 2 f_equal; apply proof_irr.
        
        - (* not at external *)
          jmstep_inv. getThread_inv.
          injection H as <-.
          erewrite corestep_not_at_external in Hat_external. discriminate.
          unfold SEM.Sem in *.
          rewrite SEM.CLN_msem.
          eapply stepi.
          
        - (* not in Kblocked *)
          jmstep_inv.
          all: getThread_inv.
          all: congruence.
          
        - (* not halted *)
          jmstep_inv. getThread_inv.
          injection H as <-.
          erewrite corestep_not_halted in Hcant. discriminate.
          unfold SEM.Sem in *.
          rewrite SEM.CLN_msem.
          eapply stepi.
      }
      (* end of internal step *)
      
      (* thread[i] is running and about to call an external: Krun (at_ex c) -> Kblocked c *)
      {
        inversion jmstep; subst; try inversion HschedN; subst tid;
          unfold ThreadPool.containsThread, is_true in *;
          try congruence.
        
        - (* not in Kinit *)
          jmstep_inv. getThread_inv. congruence.
        
        - (* not in Kresume *)
          jmstep_inv. getThread_inv. congruence.
        
        - (* not a corestep *)
          jmstep_inv. getThread_inv. injection H as <-.
          pose proof corestep_not_at_external _ _ _ _ _ _ Hcorestep.
          rewrite Ejuicy_sem in *.
          discriminate.
        
        - (* we are at an at_ex now *)
          jmstep_inv. getThread_inv.
          injection H as <-.
          rename m' into m.
          right. (* no aging *)
          
          match goal with |- _ _ (_, _, (_, ?tp)) => set (tp' := tp) end.
          assert (compat' : mem_compatible_with tp' m Phi).
          {
            clear safety wellformed unique.
            destruct compat as [JA MC LW LC LJ].
            constructor; [ | | | | ].
            - destruct JA as [tp phithreads philocks Phi jointhreads joinlocks join].
              econstructor; eauto.
            - apply MC.
            - intros b o H.
              apply (LW b o H).
            - apply LC.
            - apply LJ.
          }
          
          apply state_invariant_c with (PHI := Phi) (mcompat := compat').
          + assumption.
          
          + (* matchfunspec *)
            assumption.
          
          + (* lock sparsity *)
            auto.
          
          + (* lock coherence *)
            unfold lock_coherence' in *.
            exact_eq lock_coh.
            f_equal.
            f_equal.
            apply proof_irr.
          
          + (* safety (same, except one thing is Kblocked instead of Krun) *)
            intros i0 cnti0' ora.
            destruct (eq_dec i i0) as [ii0 | ii0].
            * subst i0.
              unfold tp'.
              rewrite ThreadPool.gssThreadCC.
              specialize (safety i cnti ora).
              rewrite Eci in safety.
              simpl.
              simpl in safety.
              unfold jm_ in *.
              erewrite personal_mem_ext.
              -- apply safety.
              -- intros i0 cnti1 cnti'.
                 apply ThreadPool.gThreadCR.
            * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
              unfold tp'.
              rewrite <- (@ThreadPool.gsoThreadCC _ _ tp ii0 ctn cnti0).
              specialize (safety i0 cnti0 ora).
              clear -safety.
              destruct (@ThreadPool.getThreadC i0 tp cnti0).
              -- unfold jm_ in *.
                 erewrite personal_mem_ext.
                 ++ apply safety.
                 ++ intros; apply ThreadPool.gThreadCR.
              -- unfold jm_ in *.
                 erewrite personal_mem_ext.
                 ++ apply safety.
                 ++ intros; apply ThreadPool.gThreadCR.
              -- unfold jm_ in *.
                 intros c' E.
                 erewrite personal_mem_ext.
                 ++ apply safety, E.
                 ++ intros; apply ThreadPool.gThreadCR.
              -- constructor.
          
          + (* wellformed. *)
            intros i0 cnti0'.
            destruct (eq_dec i i0) as [ii0 | ii0].
            * subst i0.
              unfold tp'.
              rewrite ThreadPool.gssThreadCC.
              simpl.
              congruence.
            * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
              unfold tp'.
              rewrite <- (@ThreadPool.gsoThreadCC _ _ tp ii0 ctn cnti0).
              specialize (wellformed i0 cnti0).
              destruct (@ThreadPool.getThreadC i0 tp cnti0).
              -- constructor.
              -- apply wellformed.
              -- apply wellformed.
              -- constructor.
          
          + (* uniqueness *)
            intros notalone i0 cnti0' q Eci0.
            pose proof (unique notalone i0 cnti0' q) as unique'.
            destruct (eq_dec i i0) as [ii0 | ii0].
            * subst i0.
              unfold tp' in Eci0.
              rewrite ThreadPool.gssThreadCC in Eci0.
              discriminate.
            * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
              unfold tp' in Eci0.
              clear safety wellformed.
              rewrite <- (@gsoThreadCC _ _ tp ii0 ctn cnti0) in Eci0.
              destruct (unique notalone i cnti _ Eci).
              destruct (unique notalone i0 cnti0 q Eci0).
              congruence.
        
        - (* not in Kblocked *)
          jmstep_inv.
          all: getThread_inv.
          all: congruence.
          
        - (* not halted *)
          jmstep_inv. getThread_inv.
          injection H as <-.
          erewrite at_external_not_halted in Hcant. discriminate.
          unfold SEM.Sem in *.
          rewrite SEM.CLN_msem.
          simpl.
          congruence.
      } (* end of Krun (at_ex c) -> Kblocked c *)
    } (* end of Krun *)
    
    (* thread[i] is in Kblocked *)
    { (* only one possible jmstep, in fact divided into 6 sync steps *)
      inversion jmstep; try inversion HschedN; subst tid;
        unfold ThreadPool.containsThread, is_true in *;
        try congruence; try subst;
        try solve [jmstep_inv; getThread_inv; congruence].
      
      simpl SCH.schedSkip in *.
      left (* TO BE CHANGED *).
      (* left (* we need aging, because we're using the safety of the call *). *)
      match goal with |- _ _ _ (?M, _, (_, ?TP)) => set (tp_ := TP); set (m_ := M) end.
      pose (compat_ := mem_compatible_with tp_ m_ (age_to n Phi)).
      jmstep_inv.
      
      cleanup.
      assert (El : level (getThreadR Htid) - 1 = n). {
        rewrite getThread_level with (Phi := Phi).
        - cleanup.
          rewrite lev.
          omega.
        - destruct compat. auto.
      }
      cleanup.
      
      pose proof mem_compatible_with_age compat (n := n) as compat_aged.
      
      - (* the case of acquire *)
        assert (compat' : compat_). {
          subst compat_ tp_ m_.
          rewrite El.
          constructor.
          - destruct compat as [J].
            clear -J lev His_unlocked Hadd_lock_res.
            rewrite join_all_joinlist in *.
            rewrite maps_age_to.
            rewrite maps_updlock1.
            erewrite maps_getlock3 in J; eauto.
            rewrite maps_remLockSet_updThread.
            rewrite maps_updthread.
            simpl map.
            assert (pr:containsThread (remLockSet tp (b, Int.intval ofs)) i) by auto.
            rewrite (maps_getthread i _ pr) in J.
            rewrite gRemLockSetRes with (cnti := Htid) in J. clear pr.
            revert Hadd_lock_res J.
            generalize (getThreadR Htid) d_phi (m_phi jm').
            generalize (all_but i (maps (remLockSet tp (b, Int.intval ofs)))).
            cleanup.
            clear -lev.
            intros l a b c j h.
            rewrite Permutation.perm_swap in h.
            pose proof @joinlist_age_to _ _ _ _ _ n _ _ h as h'.
            simpl map in h'.
            apply age_to_join_eq with (k := n) in j; auto.
            + eapply joinlist_merge; eassumption.
            + cut (level c = level Phi). omega.
              apply join_level in j. destruct j.
              eapply (joinlist_level a) in h.
              * congruence.
              * left; auto.
          
          - (* mem_cohere' *)
            destruct compat as [J MC].
            clear safety lock_coh jmstep.
            eapply mem_cohere'_store with
            (tp := age_tp_to n tp)
              (Hcmpt := mem_compatible_forget compat_aged)
              (i := Int.zero).
            + cleanup.
              rewrite lset_age_tp_to.
              rewrite AMap_find_map_option_map.
              rewrite His_unlocked. simpl. congruence.
            + exact_eq Hstore.
              f_equal.
              f_equal.
              apply restrPermMap_ext.
              unfold lockSet in *.
              rewrite lset_age_tp_to.
              intros b0.
              rewrite (@A2PMap_option_map rmap (lset tp)).
              reflexivity.
              
            + auto.
          
          - (* lockSet_Writable *)
            pose proof (loc_writable compat) as lw.
            intros b' ofs' is; specialize (lw b' ofs').
            destruct (eq_dec (b, Int.intval ofs) (b', ofs')).
            + injection e as <- <- .
              intros ofs0 int0.
              rewrite (Mem.store_access _ _ _ _ _ _ Hstore).
              pose proof restrPermMap_Max as RR.
              unfold permission_at in RR.
              rewrite RR; clear RR.
              clear is.
              assert_specialize lw. {
                clear lw.
                cleanup.
                rewrite His_unlocked.
                reflexivity.
              }
              specialize (lw ofs0).
              autospec lw.
              exact_eq lw; f_equal.
              unfold getMaxPerm in *.
              rewrite PMap.gmap.
              reflexivity.
            + assert_specialize lw. {
                simpl in is.
                rewrite AMap_find_map_option_map in is.
                rewrite AMap_find_add in is.
                if_tac in is. tauto.
                exact_eq is.
                unfold ssrbool.isSome in *.
                cleanup.
                destruct (AMap.find (elt:=option rmap) (b', ofs') (lset tp));
                  reflexivity.
              }
              intros ofs0 inter.
              specialize (lw ofs0 inter).
              exact_eq lw. f_equal.
              set (m_ := restrPermMap _) in Hstore.
              change (max_access_at m (b', ofs0) = max_access_at (m_dry jm') (b', ofs0)).
              transitivity (max_access_at m_ (b', ofs0)).
              * unfold m_.
                rewrite restrPermMap_max.
                reflexivity.
              * pose proof store_outside' _ _ _ _ _ _ Hstore as SO.
                unfold access_at in *.
                destruct SO as (_ & SO & _).
                apply equal_f with (x := (b', ofs0)) in SO.
                apply equal_f with (x := Max) in SO.
                apply SO.
          - (* juicyLocks_in_lockSet *)
            pose proof jloc_in_set compat as jl.
            intros loc sh1 sh1' pp z E.
            cleanup.
            (* rewrite lset_age_tp_to. *)
            (* rewrite AMap_find_map_option_map. *)
            Lemma isSome_option_map {A B} (f : A -> B) o : ssrbool.isSome (option_map f o) = ssrbool.isSome o.
            Proof.
              destruct o; reflexivity.
            Qed.
            (* rewrite isSome_option_map. *)
            apply juicyLocks_in_lockSet_age with (n := n) in jl.
            specialize (jl loc sh1 sh1' pp z E).
            simpl.
            Lemma AMap_map_add {A B} (f : A -> B) m x y :
              AMap.Equal
                (AMap.map f (AMap.add x y m))
                (AMap.add x (f y) (AMap.map f m)).
            Proof.
              intros k.
              rewrite AMap_find_map_option_map.
              rewrite AMap_find_add.
              rewrite AMap_find_add.
              rewrite AMap_find_map_option_map.
              destruct (AMap.find (elt:=A) k m); if_tac; auto.
            Qed.
            rewrite AMap_map_add.
            rewrite AMap_find_add.
            if_tac. reflexivity.
            rewrite lset_age_tp_to in jl.
            apply jl.
          
          - (* lockSet_in_juicyLocks *)
            pose proof lset_in_juice compat as lj.
            intros loc; specialize (lj loc).
            simpl.
            rewrite AMap_map_add.
            rewrite AMap_find_add.
            rewrite AMap_find_map_option_map.
            if_tac; swap 1 2.
            + cleanup.
              rewrite isSome_option_map.
              intros is; specialize (lj is).
              destruct lj as (sh' & psh' & P & E).
              rewrite age_to_resource_at.
              rewrite E. simpl. eauto.
            + intros _. subst loc.
              assert_specialize lj. {
                cleanup.
                rewrite His_unlocked.
                reflexivity.
              }
              destruct lj as (sh' & psh' & P & E).
              rewrite age_to_resource_at.
              rewrite E. simpl. eauto.
        }
        
        apply state_invariant_c with (mcompat := compat').
        + (* level *)
          apply level_age_to. omega.
        
        + (* matchfunspec *)
          revert gam. clear.
          Lemma matchfunspec_age_to e Gamma n Phi :
            matchfunspec e Gamma Phi ->
            matchfunspec e Gamma (age_to n Phi).
          Proof.
            unfold matchfunspec in *.
            Lemma age_to_mpred (P : mpred) x n : (* TODO remove this (copied in age_to.v) *)
              app_pred P x ->
              app_pred P (age_to n x).
            Proof.
              apply age_to_ind. clear x n.
              destruct P as [x h]. apply h.
            Qed.
            apply age_to_mpred.
          Qed.
          apply matchfunspec_age_to.
        
        + (* lock sparsity *)
          unfold tp_ in *.
          simpl.
          cleanup.
          eapply sparsity_same_support with (lset tp); auto.
          apply lset_same_support_sym.
          eapply lset_same_support_trans.
          * apply lset_same_support_map.
          * apply lset_same_support_sym.
            apply same_support_change_lock.
            cleanup.
            rewrite His_unlocked. congruence.
        
        + (* lock coherence *)
          intros loc.
          simpl (AMap.find _ _).
          rewrite AMap_find_map_option_map.
          rewrite AMap_find_add.
          specialize (lock_coh loc).
          if_tac.
          
          * (* current lock is acquired: load is indeed 0 *)
            { subst loc.
              split; swap 1 2.
              - (* the rmap is unchanged (but we lose the SAT information) *)
                cut (exists sh0 R0, (LK_at R0 sh0 (b, Int.intval ofs)) Phi).
                { intros (sh0 & R0 & AP). exists sh0, R0. apply age_to_mpred, AP. }
                cleanup.
                rewrite His_unlocked in lock_coh.
                destruct lock_coh as (H & ? & ? & lk & _).
                eauto.
              
              - (* in dry : it is 0 *)
                unfold m_ in *; clear m_.
                unfold compat_ in *; clear compat_.
                unfold load_at.
                clear (* lock_coh *) Htstep Hload.
                
                unfold Mem.load. simpl fst; simpl snd.
                if_tac [H|H].
                + rewrite restrPermMap_mem_contents.
                  apply Mem.load_store_same in Hstore.
                  unfold Mem.load in Hstore.
                  if_tac in Hstore; [ | discriminate ].
                  apply Hstore.
                + exfalso.
                  apply H; clear H.
                  apply islock_valid_access.
                  * apply Mem.load_store_same in Hstore.
                    unfold Mem.load in Hstore.
                    if_tac [[H H']|H] in Hstore; [ | discriminate ].
                    apply H'.
                  * unfold tp_.
                    Lemma LockRes_age_content1 js n a :
                      lockRes (age_tp_to n js) a = option_map (option_map (age_to n)) (lockRes js a).
                    Proof.
                      cleanup.
                      rewrite lset_age_tp_to, AMap_find_map_option_map.
                      reflexivity.
                    Qed.
                    rewrite LockRes_age_content1.
                    rewrite JTP.gssLockRes. simpl. congruence.
                  * congruence.
            }
          
          * (* not the current lock *)
            rewrite El.
            destruct (AMap.find (elt:=option rmap) loc (lset tp)) as [o|] eqn:Eo; swap 1 2.
            {
              simpl.
              clear -lock_coh.
              (* use lock_coh and the lemma [age_to_resource_at] in a laborious way? *)
              (* we need a version of the lemma in the opposite direction *)
              intros sh sh' z P; split; intros E.
              admit.
              admit.
              (* now simpl; auto (* not even a lock *). *)
            }
            (* options:
             - maintain the invariant that the distance between
                two locks is >= 4 (or =0)
             - try to relate to the wet memory?
             - others?
             *)
            set (u := load_at _ _).
            set (v := load_at _ _) in lock_coh.
            assert (L : forall val, v = Some val -> u = Some val); unfold u, v in *.
            (* ; clear u v. *)
            {
              intros val.
              unfold load_at in *.
              clear lock_coh.
              destruct loc as (b', ofs'). simpl fst in *; simpl snd in *.
              pose proof sparse (b, Int.intval ofs) (b', ofs') as SPA.
              assert_specialize SPA by (cleanup; congruence).
              assert_specialize SPA by (cleanup; congruence).
              simpl in SPA.
              destruct SPA as [SPA|SPA]; [ tauto | ].
              unfold Mem.load in *.
              if_tac [V|V]; [ | congruence].
              if_tac [V'|V'].
              - do 2 rewrite restrPermMap_mem_contents.
                intros G; exact_eq G.
                f_equal.
                f_equal.
                f_equal.
                simpl.
                
                pose proof store_outside' _ _ _ _ _ _ Hstore as OUT.
                destruct OUT as (OUT, _).
                cut (forall z,
                        (0 <= z < 4)%Z ->
                        ZMap.get (ofs' + z)%Z (Mem.mem_contents m) !! b' =
                        ZMap.get (ofs' + z)%Z (Mem.mem_contents m_) !! b').
                {
                  intros G.
                  repeat rewrite <- Z.add_assoc.
                  f_equal.
                  - specialize (G 0%Z ltac:(omega)).
                    exact_eq G. repeat f_equal; auto with zarith.
                  - f_equal; [apply G; omega | ].
                    f_equal; [apply G; omega | ].
                    f_equal; apply G; omega.
                }
                intros z Iz.
                specialize (OUT b' (ofs' + z)%Z).
                
                destruct OUT as [[-> OUT]|OUT]; [ | clear SPA].
                + exfalso.
                  destruct SPA as [? | [_ SPA]]; [ tauto | ].
                  eapply far_range in SPA. apply SPA; clear SPA.
                  apply OUT. omega.
                + unfold contents_at in *.
                  simpl in OUT.
                  apply OUT.
              
              - exfalso.
                apply V'; clear V'.
                unfold Mem.valid_access in *.
                split. 2:apply V. destruct V as [V _].
                unfold Mem.range_perm in *.
                intros ofs0 int0; specialize (V ofs0 int0).
                unfold Mem.perm in *.
                pose proof restrPermMap_Cur as RR.
                unfold permission_at in *.
                rewrite RR in *.
                unfold tp_.
                Lemma lockSet_age_to n tp :
                  lockSet (age_tp_to n tp) = lockSet tp.
                Proof.
                Admitted.  
                rewrite lockSet_age_to.
                rewrite <-lockSet_updLockSet.
                match goal with |- _ ?a _ => cut (a = Some Writable) end.
                { intros ->. constructor. }
                
                destruct SPA as [bOUT | [<- ofsOUT]].
                + rewrite gsoLockSet_2; auto.
                  eapply lockSet_spec_2.
                  * hnf; simpl. eauto.
                  * cleanup. rewrite Eo. reflexivity.
                + rewrite gsoLockSet_1; auto.
                  * eapply lockSet_spec_2.
                    -- hnf; simpl. eauto.
                    -- cleanup. rewrite Eo. reflexivity.
                  * unfold far in *.
                    simpl in *.
                    zify.
                    omega.
            }
            destruct o; destruct lock_coh as (Load & sh' & R' & lks); split.
            -- now intuition.
            -- exists sh', R'.
               destruct lks as (lk, sat); split.
               ++ revert lk.
                  apply age_to_mpred.
               ++ destruct sat as [sat|sat].
                  ** left; revert sat.
                     unfold age_to in *.
                     rewrite age_by_age_by.
                     Lemma age_by_age_by_pred {A} `{agA : ageable A} (P : pred A) x n1 n2 :
                       le n1 n2 ->
                       app_pred P (age_by n1 x) ->
                       app_pred P (age_by n2 x).
                     Admitted. (* TODO remove (is already in age_to.v) *)
                     apply age_by_age_by_pred.
                     omega.
                  ** congruence.
            -- now intuition.
            -- exists sh', R'.
               revert lks.
               apply age_to_mpred.
        
        + (* safety *)
          intros j lj ora.
          specialize (safety j lj ora).
          unfold tp_.
          unshelve erewrite <-gtc_age. auto.
          unshelve erewrite gLockSetCode; auto.
          destruct (eq_dec i j).
          * {
              (* use the "well formed" property to derive that this is
              an external call, and derive safety from this.  But the
              level has to be decreased, here. *)
              subst j.
              rewrite gssThreadCode.
              replace lj with Htid in safety by apply proof_irr.
              rewrite Hthread in safety.
              specialize (wellformed i Htid).
              rewrite Hthread in wellformed.
              intros c' Ec'.
              inversion safety as [ | ?????? step | ???????? ae Pre Post Safe | ????? Ha]; swap 2 3.
              - (* not corestep *)
                exfalso.
                clear -Hat_external step.
                apply corestep_not_at_external in step.
                rewrite jstep.JuicyFSem.t_obligation_3 in step.
                set (u := at_external _) in Hat_external.
                set (v := at_external _) in step.
                assert (u = v).
                { unfold u, v. f_equal.
                  unfold SEM.Sem in *.
                  rewrite SEM.CLN_msem.
                  reflexivity. }
                congruence.
              
              - (* not halted *)
                exfalso.
                clear -Hat_external Ha.
                assert (Ae : at_external SEM.Sem c <> None). congruence.
                eapply at_external_not_halted in Ae.
                unfold juicy_core_sem in *.
                unfold cl_core_sem in *.
                simpl in *.
                unfold SEM.Sem in *.
                rewrite SEM.CLN_msem in *.
                simpl in *.
                congruence.
              
              - (* at_external : we can now use safety *)
                subst z c0 m0.
                destruct Post with
                  (ret := Some (Vint Int.zero))
                  (m' := jm_ lj compat')
                  (z' := ora) (n' := n) as (c'' & Ec'' & Safe').
                + auto.
                + hnf. (* ouch *) admit.
                + (* ouch, we must satisfy the post condition *)
                  unfold ext_spec_post in *.
                  admit.
                + exact_eq Safe'.
                  unfold jsafeN in *.
                  unfold juicy_safety.safeN in *.
                  f_equal.
                  cut (Some c'' = Some c'). injection 1; auto.
                  rewrite <-Ec'', <-Ec'.
                  unfold cl_core_sem; simpl.
                  auto.
            }
          
          * unshelve erewrite gsoThreadCode; auto.
            admit.
            (* destruct (@getThreadC j tp lj). *)
            (* use safety, but there are [personal_mem] things involved *)
        
        + (* well_formedness *)
          intros j lj.
          unfold tp_.
          specialize (wellformed j lj).
          Set Printing Implicit.
          unshelve erewrite <-gtc_age. auto.
          unshelve erewrite gLockSetCode; auto.
          destruct (eq_dec i j).
          * subst j.
            rewrite gssThreadCode.
            replace lj with Htid in wellformed by apply proof_irr.
            rewrite Hthread in wellformed.
            auto.
          * unshelve erewrite gsoThreadCode; auto.
        
        + (* uniqueness *)
          apply no_Krun_unique_Krun.
          (* unfold tp_ in *. *)
          unfold tp_.
          Unset Printing Implicit.
          rewrite no_Krun_age_tp_to.
          apply no_Krun_updLockSet.
          apply no_Krun_stable. congruence.
          eapply unique_Krun_no_Krun. eassumption.
          instantiate (1 := Htid). rewrite Hthread.
          congruence.
      
      - (* the case of release *)
        admit.
      
      - (* the case of spawn *)
        admit.
      
      - (* the case of makelock *)
        admit.
      
      - (* the case of freelock *)
        admit.
      
      - (* the case of acq-fail *)
        admit.
    }
    
    (*thread[i] is in Kresume *)
    { (* again, only one possible case *)
      right (* no aging *).
      inversion jmstep; try inversion HschedN; subst tid;
        unfold ThreadPool.containsThread, is_true in *;
        try congruence; try subst;
        try solve [jmstep_inv; getThread_inv; congruence].
      jmstep_inv.
      rename m' into m.
      assert (compat' : mem_compatible_with (updThreadC ctn (Krun c')) m Phi).
      {
        clear safety wellformed unique.
        destruct compat as [JA MC LW LC LJ].
        constructor; [ | | | | ].
        - destruct JA as [tp phithreads philocks Phi jointhreads joinlocks join].
          econstructor; eauto.
        - apply MC.
        - intros b o H.
          apply (LW b o H).
        - apply LC.
        - apply LJ.
      }
      
      apply state_invariant_c with (PHI := Phi) (mcompat := compat').
      + (* level *)
        assumption.
      
      + (* matchfunspec *)
        assumption.
      
      + (* lock sparsity *)
        auto.
      
      + (* lock coherence *)
        unfold lock_coherence' in *.
        exact_eq lock_coh.
        f_equal.
        f_equal.
        apply proof_irr.
      
      + (* safety : the new c' is derived from "after_external", so
           that's not so good? *)
        intros i0 cnti0' ora.
        destruct (eq_dec i i0) as [ii0 | ii0].
        * subst i0.
          rewrite ThreadPool.gssThreadCC.
          specialize (safety i cnti ora).
          rewrite Eci in safety.
          simpl.
          (* apply safe_downward1. *)
          change (jsafeN Jspec' ge (S n) ora c' (jm_ cnti0' compat')).
          getThread_inv. injection H as -> -> .
          specialize (safety c').
          unfold SEM.Sem in *.
          rewrite SEM.CLN_msem in *.
          specialize (safety ltac:(eauto)).
          exact_eq safety.
          f_equal.
          unfold jm_ in *.
          apply personal_mem_ext.
          intros i0 cnti0 cnti'.
          unshelve erewrite gThreadCR; auto.
        * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
          rewrite <- (@ThreadPool.gsoThreadCC _ _ tp ii0 ctn cnti0).
          specialize (safety i0 cnti0 ora).
          clear -safety.
          destruct (@ThreadPool.getThreadC i0 tp cnti0).
          -- unfold jm_ in *.
             erewrite personal_mem_ext.
             ++ apply safety.
             ++ intros; apply ThreadPool.gThreadCR.
          -- unfold jm_ in *.
             erewrite personal_mem_ext.
             ++ apply safety.
             ++ intros; apply ThreadPool.gThreadCR.
          -- unfold jm_ in *.
             erewrite personal_mem_ext.
             ++ intros c'' E; apply safety, E.
             ++ intros; apply ThreadPool.gThreadCR.
          -- constructor.
      
      + (* wellformed. *)
        intros i0 cnti0'.
        destruct (eq_dec i i0) as [ii0 | ii0].
        * subst i0.
          rewrite ThreadPool.gssThreadCC.
          constructor.
        * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
          rewrite <- (@ThreadPool.gsoThreadCC _ _ tp ii0 ctn cnti0).
          specialize (wellformed i0 cnti0).
          destruct (@ThreadPool.getThreadC i0 tp cnti0).
          -- constructor.
          -- apply wellformed.
          -- apply wellformed.
          -- constructor.
             
      + (* uniqueness *)
        intros notalone i0 cnti0' q Eci0.
        pose proof (unique notalone i0 cnti0' q) as unique'.
        destruct (eq_dec i i0) as [ii0 | ii0].
        * subst i0.
          eauto.
        * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
          clear safety wellformed.
          rewrite <- (@gsoThreadCC _ _ tp ii0 ctn cnti0) in Eci0.
          destruct (unique notalone i0 cnti0 q Eci0).
          congruence.
    }
    
    (* thread[i] is in Kinit *)
    {
      (* still unclear how to handle safety of Kinit states *)
      admit.
    }
  Admitted.

  Lemma state_invariant_step Gamma n state :
    state_invariant Jspec' Gamma (S n) state ->
    exists state',
      state_step state state' /\
      (state_invariant Jspec' Gamma n state' \/
       state_invariant Jspec' Gamma (S n) state').
  Proof.
    intros inv.
    destruct (progress _ _ _ inv) as (state', step).
    exists state'; split; [ now apply step | ].
    eapply preservation; eauto.
  Qed.
  
  (* another, looser invariant to have more standard preservation
  statement *)
  Definition inv Gamma n state :=
    exists m, n <= m /\ state_invariant Jspec' Gamma m state.
  
  Theorem progress_inv Gamma n state :
    inv Gamma (S n) state -> exists state', state_step state state'.
  Proof.
    intros (m & lm & i).
    replace m with (S (m - 1)) in i by omega.
    apply (progress _ _ _ i).
  Qed.
  
  Theorem preservation_inv Gamma n state state' :
    state_step state state' -> inv Gamma (S n) state -> inv Gamma n state'.
  Proof.
    unfold inv; intros s (m & lm & i).
    replace m with (S (m - 1)) in i by omega.
    destruct (preservation _ _ _ _ s i) as [H|H].
    - exists (m - 1). split. omega. assumption.
    - exists m. split. omega. exact_eq H; f_equal. omega.
  Qed.
  
  Lemma inv_step Gamma n state :
    inv Gamma (S n) state ->
    exists state',
      state_step state state' /\
      inv Gamma n state'.
  Proof.
    intros inv.
    destruct (progress_inv _ _ _ inv) as (state', step).
    exists state'; split; [ now apply step | ].
    eapply preservation_inv; eauto.
  Qed.
  
End Simulation.

Inductive jmsafe : nat -> cm_state -> Prop :=
| jmsafe_0 m ge sch tp : jmsafe 0 (m, ge, (sch, tp))
| jmsafe_halted n m ge tp : jmsafe n (m, ge, (nil, tp))
| jmsafe_core n m m' ge sch tp tp':
    @JuicyMachine.machine_step ge sch nil tp m sch nil tp' m' ->
    jmsafe n (m', ge, (sch, tp')) ->
    jmsafe (S n) (m, ge, (sch, tp))
| jmsafe_sch n m m' ge i sch tp tp':
    @JuicyMachine.machine_step ge (i :: sch) nil tp m sch nil tp' m' ->
    (forall sch', jmsafe n (m', ge, (sch', tp'))) ->
    jmsafe (S n) (m, ge, (i :: sch, tp)).

(*
Inductive jmsafe : nat -> cm_state -> Prop :=
| jmsafe_0 m ge sch tp : jmsafe 0 (m, ge, (sch, tp))
| jmsafe_halted n m ge tp : jmsafe n (m, ge, (nil, tp))
| jmsafe_sch n m m' ge i sch tp tp':
    @JuicyMachine.machine_step ge (i :: sch) nil tp m sch nil tp' m' ->
    (forall sch', unique_Krun tp sch' -> jmsafe n (m', ge, (sch', tp'))) ->
    jmsafe (S n) (m, ge, (i :: sch, tp)).
 *)

Lemma step_sch_irr ge i sch sch' tp m tp' m' :
  @JuicyMachine.machine_step ge (i :: sch) nil tp m sch nil tp' m' ->
  @JuicyMachine.machine_step ge (i :: sch') nil tp m sch' nil tp' m'.
Proof.
  intros step.
  assert (i :: sch <> sch) by (clear; induction sch; congruence).
  inversion step; try solve [exfalso; eauto].
  - now eapply JuicyMachine.suspend_step; eauto.
  - now eapply JuicyMachine.sync_step; eauto.
  - now eapply JuicyMachine.halted_step; eauto.
  - now eapply JuicyMachine.schedfail; eauto.
Qed.

Lemma inv_sch_irr CS ext_link Gamma n m ge i sch sch' tp :
  inv CS ext_link Gamma n (m, ge, (i :: sch, tp)) ->
  inv CS ext_link Gamma n (m, ge, (i :: sch', tp)).
Proof.
  intros (k & lkm & Hk).
  exists k; split; auto.
  eapply state_invariant_sch_irr, Hk.
Qed.


(*+ Final instantiation *)

Section Safety.
  Variables
    (CS : compspecs)
    (V : varspecs)
    (G : funspecs)
    (ext_link : string -> ident)
    (ext_link_inj : forall s1 s2, ext_link s1 = ext_link s2 -> s1 = s2)
    (prog : Clight.program)
    (all_safe : semax_prog.semax_prog (Concurrent_Oracular_Espec CS ext_link) prog V G)
    (init_mem_not_none : Genv.init_mem prog <> None).

  Lemma invariant_safe Gamma n state :
    inv CS ext_link Gamma n state -> jmsafe n state.
  Proof.
    intros INV.
    pose proof (progress_inv CS ext_link ext_link_inj) as Progress.
    pose proof (preservation_inv CS ext_link ext_link_inj) as Preservation.
    revert state INV.
    induction n; intros ((m, ge), (sch, tp)) INV.
    - apply jmsafe_0.
    - destruct sch.
      + apply jmsafe_halted.
      + destruct (Progress _ _ _ INV) as (state', step).
        pose proof (Preservation _ _ _ _ step INV).
        inversion step as [ | ge' m0 m' sch' sch'' tp0 tp' jmstep ]; subst; simpl in *.
        inversion jmstep; subst.
        * eapply jmsafe_core; eauto.
        * eapply jmsafe_core; eauto.
        * eapply jmsafe_core; eauto.
        * eapply jmsafe_sch; eauto.
          intros sch'; apply IHn.
          eapply (step_sch_irr _ _ _ sch') in jmstep.
          simpl in *.
          assert (step' : state_step (m', ge, (t0 :: sch', tp)) (m', ge, (sch', tp'))).
          { constructor; auto. }
          eapply inv_sch_irr in INV.
          specialize (Preservation _ _ _ _ step' INV).
          assumption.
        * eapply jmsafe_sch; eauto.
          intros sch'; apply IHn.
          eapply (step_sch_irr _ _ _ sch') in jmstep.
          simpl in *.
          assert (step' : state_step (m, ge, (t0 :: sch', tp)) (m', ge, (sch', tp'))).
          { constructor; auto. }
          eapply inv_sch_irr in INV.
          specialize (Preservation _ _ _ _ step' INV).
          assumption.
        * eapply jmsafe_sch; eauto.
          intros sch'; apply IHn.
          eapply (step_sch_irr _ _ _ sch') in jmstep.
          simpl in *.
          assert (step' : state_step (m', ge, (t0 :: sch', tp')) (m', ge, (sch', tp'))).
          { constructor; auto. }
          eapply inv_sch_irr in INV.
          specialize (Preservation _ _ _ _ step' INV).
          assumption.
        * eapply jmsafe_sch; eauto.
          intros sch'; apply IHn.
          eapply (step_sch_irr _ _ _ sch') in jmstep.
          simpl in *.
          assert (step' : state_step (m', ge, (t0 :: sch', tp')) (m', ge, (sch', tp'))).
          { constructor; auto. }
          eapply inv_sch_irr in INV.
          specialize (Preservation _ _ _ _ step' INV).
          assumption.
  Qed.
  
  Definition init_mem : { m | Genv.init_mem prog = Some m } := init_m prog init_mem_not_none.
  
  Definition spr :=
    semax_prog_rule
      (Concurrent_Oracular_Espec CS ext_link) V G prog
      (proj1_sig init_mem) all_safe (proj2_sig init_mem).
  
  Definition initial_corestate : corestate := projT1 (projT2 spr).
  
  Definition initial_jm (n : nat) : juicy_mem := proj1_sig (snd (projT2 (projT2 spr)) n).
  
  Definition initial_machine_state (n : nat) :=
    ThreadPool.mk
      (pos.mkPos (le_n 1))
      (fun _ => Krun initial_corestate)
      (fun _ => m_phi (initial_jm n))
      (addressFiniteMap.AMap.empty _).

  Definition NoExternal_Espec : external_specification mem external_function unit :=
    Build_external_specification
      _ _ _
      (* no external calls from the machine *)
      (fun _ => False)
      (fun _ _ _ _ _ _ _ => False)
      (fun _ _ _ _ _ _ _ => False)
      (* when the machine is halted, it means no more schedule, there
      is nothing to check: *)
      (fun _ _ _ => Logic.True).
  
  Definition NoExternal_Hrel : nat -> mem -> mem -> Prop := fun _ _ _ => False.
  
  (* We state the theorem in terms of [safeN_] but because there are
  no external, this really just says that the initial state is
  "angelically safe" : for every schedule and every fuel n, there is a
  path either ending on an empty schedule or consuming all the
  fuel. *)
  
  Theorem safe_initial_state : forall sch r n genv_symb,
      safeN_
        (G := genv)
        (C := schedule * list _ * ThreadPool.t)
        (M := mem)
        (Z := unit)
        (genv_symb := genv_symb)
        (Hrel := NoExternal_Hrel)
        (JuicyMachine.MachineSemantics sch r)
        NoExternal_Espec
        (globalenv prog)
        n
        tt
        (sch, nil, initial_machine_state n)
        (proj1_sig init_mem).
  Proof.
    intros sch r n thisfunction.
    pose proof initial_invariant CS V G ext_link prog as INIT.
    repeat (specialize (INIT ltac:(assumption))).
    match type of INIT with
      _ _ ?a n ?b =>
      assert (init : inv CS ext_link a n b) by (hnf; eauto)
    end.
    pose proof inv_step CS ext_link ext_link_inj as SIM.
    clear INIT; revert init.
    unfold initial_state, initial_machine_state.
    unfold initial_corestate, initial_jm, spr, init_mem.
    match goal with |- context[(sch, ?tp)] => generalize tp end.
    match goal with |- context[(proj1_sig ?m)] => generalize (proj1_sig m) end.
    (* here we decorelate the CoreSemantics parameters from the
    initial state parameters *)
    generalize sch at 2.
    generalize (globalenv prog), sch.
    clear -SIM.
    induction n; intros g sch schSEM m t INV; [ now constructor | ].
    destruct (SIM _ _ _ INV) as [cm' [step INV']].
    inversion step as [ | ? ? m' ? sch' ? tp' STEP ]; subst; clear step.
    - (* empty schedule *)
      eapply safeN_halted.
      + reflexivity.
      + apply I.
    - (* a step can be taken *)
      eapply safeN_step with (c' := (sch', nil, tp')) (m'0 := m').
      + eapply STEP.
      + apply IHn.
        apply INV'.
  Qed.
  
  (* The following is a slightly stronger result, proving [jmsafe]
  i.e. a safety that universally quantifies over all schedule each
  time a part of the schedule is consumed *)

  Theorem jmsafe_initial_state sch n :
    jmsafe n ((proj1_sig init_mem, globalenv prog), (sch, initial_machine_state n)).
  Proof.
    eapply invariant_safe.
    exists n; split; auto; apply initial_invariant.
  Qed.
  
  Lemma jmsafe_csafe n m ge sch s : jmsafe n (m, ge, (sch, s)) -> JuicyMachine.csafe ge (sch, nil, s) m n.
  Proof.
    clear.
    revert m ge sch s; induction n; intros m ge sch s SAFE.
    now constructor 1.
    inversion SAFE; subst.
    - constructor 2. reflexivity.
    - econstructor 3; simpl; eauto.
    - econstructor 4; simpl; eauto.
  Qed.
  
  (* [jmsafe] is an intermediate result, we can probably prove [csafe]
  directly *)
  
  Theorem safety_initial_state (sch : schedule) (n : nat) :
    JuicyMachine.csafe (globalenv prog) (sch, nil, initial_machine_state n) (proj1_sig init_mem) n.
  Proof.
    apply jmsafe_csafe, jmsafe_initial_state.
  Qed.
  
End Safety.
