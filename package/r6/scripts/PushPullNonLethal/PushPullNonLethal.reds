// Push/Pull Non-Lethal Impacts 1.0.0 (Cyberslop, 2026-10-30), companion to the Push And Pull Mod CET mod (Nexus 739).
//
// Why: vanilla DamageSystem.ProcessRagdollHit kills any ragdoll whose impact speed reaches
// AIGeneralSettings.ragdollImpactKillVelocityThreshold (11.5 m/s, 41 km/h) or that falls 6 m at 7 m/s:
// it calls MarkForDeath and deals max health. A pushed NPC that slams into a wall dies no matter how
// much health it has, so the CET mod's old "health floor" could never save it.
//
// What: for NPCs the CET mod marks (PushPullMarkImpact, valid a few seconds after a push or pull),
// a ragdoll impact on a conscious human is graded by its speed and fall height:
//   - under the knockout speed: vanilla bruising damage, flagged non-lethal (if it empties the health
//     bar the NPC is knocked out, not killed)
//   - knockout speed or more, or a vanilla high fall: knocked unconscious, the same path blunt weapons
//     use (NPCPuppet.OnPotentialDeath applies BaseStatusEffect.Unconscious)
//   - lethal speed or lethal fall height (0 = off): killed, as vanilla
// A body that is already unconscious or defeated takes no damage from survivable impacts.
// Machines (drones, mechs, androids: no defeat mechanic) and unmarked ragdolls stay vanilla.
// Bosses and MaxTac never take ragdoll damage in vanilla (NPCPuppet.CanReceiveDamageFromRagdollImpacts).

@addField(NPCPuppet)
private let m_pushPullUntil: Float;

@addField(NPCPuppet)
private let m_pushPullKnockoutSpeed: Float;

@addField(NPCPuppet)
private let m_pushPullLethalSpeed: Float;

@addField(NPCPuppet)
private let m_pushPullLethalFall: Float;

@addField(NPCPuppet)
private let m_pushPullImpactCount: Int32;

@addField(NPCPuppet)
private let m_pushPullLastSpeed: Float;

@addField(NPCPuppet)
private let m_pushPullLastHeight: Float;

@addField(NPCPuppet)
private let m_pushPullLastOutcome: Int32;

// Called by the CET mod on every push / pull. Speeds in m/s, height in m.
@addMethod(NPCPuppet)
public func PushPullMarkImpact(seconds: Float, knockoutSpeed: Float, lethalSpeed: Float, lethalFallHeight: Float) -> Bool {
  this.m_pushPullUntil = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame())) + seconds;
  this.m_pushPullKnockoutSpeed = knockoutSpeed;
  this.m_pushPullLethalSpeed = lethalSpeed;
  this.m_pushPullLethalFall = lethalFallHeight;
  return true;
}

@addMethod(NPCPuppet)
public func PushPullIsMarked() -> Bool {
  return this.m_pushPullUntil > 0.00 && EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame())) <= this.m_pushPullUntil;
}

// Read by the CET mod for its overlay readout and log line.
// Outcome: 0 no damage, 1 hurt (non-lethal), 2 knocked out, 3 killed (lethal impact),
// 4 already down (impact ignored), 5 machine (vanilla)
@addMethod(NPCPuppet)
public func PushPullImpactCount() -> Int32 {
  return this.m_pushPullImpactCount;
}

@addMethod(NPCPuppet)
public func PushPullLastSpeed() -> Float {
  return this.m_pushPullLastSpeed;
}

@addMethod(NPCPuppet)
public func PushPullLastHeight() -> Float {
  return this.m_pushPullLastHeight;
}

@addMethod(NPCPuppet)
public func PushPullLastOutcome() -> Int32 {
  return this.m_pushPullLastOutcome;
}

@addMethod(NPCPuppet)
public func PushPullKnockoutSpeed() -> Float {
  return this.m_pushPullKnockoutSpeed;
}

@addMethod(NPCPuppet)
public func PushPullLethalSpeed() -> Float {
  return this.m_pushPullLethalSpeed;
}

@addMethod(NPCPuppet)
public func PushPullLethalFall() -> Float {
  return this.m_pushPullLethalFall;
}

@addMethod(NPCPuppet)
public func PushPullRecordImpact(speed: Float, height: Float, outcome: Int32) -> Void {
  this.m_pushPullLastSpeed = speed;
  this.m_pushPullLastHeight = height;
  this.m_pushPullLastOutcome = outcome;
  this.m_pushPullImpactCount += 1;
  FTLog(s"[PushPullImpact] \(TDBID.ToStringDEBUG(this.GetRecordID())) \(speed * 3.60) km/h, fall \(height) m, outcome \(outcome) (0 none, 1 hurt, 2 knocked out, 3 killed, 4 already down, 5 machine)");
}

// Undo the MarkForDeath vanilla sets on a terminal-speed impact, so OnPotentialDeath knocks out instead of killing.
@addMethod(NPCPuppet)
public func PushPullClearDeathMark() -> Void {
  this.m_shouldDie = false;
}

@wrapMethod(DamageSystem)
private final func ProcessRagdollHit(hitEvent: ref<gameHitEvent>) -> Void {
  let ragdollHit: ref<gameRagdollHitEvent> = hitEvent as gameRagdollHitEvent;
  let npc: ref<NPCPuppet> = hitEvent.target as NPCPuppet;
  if !IsDefined(ragdollHit) || !IsDefined(npc) || !npc.PushPullIsMarked() {
    wrappedMethod(hitEvent);
    return;
  };

  let speed: Float = ragdollHit.speedDelta;
  let height: Float = ragdollHit.heightDelta;
  let wasMarkedForDeath: Bool = npc.IsAboutToDie();
  let conscious: Bool = npc.IsDefeatMechanicActive();
  let isHuman: Bool = Equals(npc.GetNPCType(), gamedataNPCType.Human);

  // Vanilla first: friendly targets, crowd immunity and the damage curve stay the game's
  wrappedMethod(hitEvent);
  let damage: Float = hitEvent.attackComputed.GetAttackValue(gamedataDamageType.Physical);
  if damage <= 0.00 {
    npc.PushPullRecordImpact(speed, height, 0);
    return;
  };
  if !isHuman {
    npc.PushPullRecordImpact(speed, height, 5);
    return;
  };

  let killSpeed: Float = TweakDBInterface.GetFloat(t"AIGeneralSettings.ragdollImpactKillVelocityThreshold", 11.00);
  let highFallSpeed: Float = TweakDBInterface.GetFloat(t"AIGeneralSettings.ragdollHighFallVelocityThreshold", 8.00);
  let highFallHeight: Float = TweakDBInterface.GetFloat(t"AIGeneralSettings.ragdollHighFallHeightThreshold", 6.00);
  let maxHealth: Float = GameInstance.GetStatsSystem(npc.GetGame()).GetStatValue(Cast<StatsObjectID>(npc.GetEntityID()), gamedataStatType.Health);
  let lethalSpeed: Float = npc.PushPullLethalSpeed();
  let lethalFall: Float = npc.PushPullLethalFall();
  let lethal: Bool = (lethalSpeed > 0.00 && speed >= lethalSpeed) || (lethalFall > 0.00 && height >= lethalFall && speed >= highFallSpeed);

  if lethal {
    if !npc.IsAboutToDie() {
      npc.SetMyKiller(hitEvent.attackData.GetInstigator());
      npc.MarkForDeath();
    };
    hitEvent.attackComputed.SetAttackValue(maxHealth, gamedataDamageType.Physical);
    hitEvent.attackData.AddFlag(hitFlag.DeterministicDamage, n"ragdoll_collision");
    npc.PushPullRecordImpact(speed, height, 3);
    return;
  };

  if !wasMarkedForDeath {
    npc.PushPullClearDeathMark();
  };

  if !conscious {
    // Already unconscious or defeated: a survivable impact does not finish the body off
    hitEvent.attackComputed.SetAttackValue(0.00);
    npc.PushPullRecordImpact(speed, height, 4);
    return;
  };

  hitEvent.attackData.AddFlag(hitFlag.Nonlethal, n"PushPull impact");
  if speed >= MinF(npc.PushPullKnockoutSpeed(), killSpeed) || (speed >= highFallSpeed && height >= highFallHeight) {
    hitEvent.attackComputed.SetAttackValue(maxHealth, gamedataDamageType.Physical);
    hitEvent.attackData.AddFlag(hitFlag.DeterministicDamage, n"ragdoll_collision");
    npc.PushPullRecordImpact(speed, height, 2);
  } else {
    npc.PushPullRecordImpact(speed, height, 1);
  };
}

// Gorilla Yeet 0.5.5 (Cyberslop, 2026-10-30). Its Non-lethal option lowers health after the hit, which cannot
// stop the punch itself: a punch that empties the health bar leaves the NPC Defeated, and the next hit kills it.
// While the option is on, the punches that yeet carry the vanilla Nonlethal flag, so the hit reaction can't kill
// (HitReactionComponent.CanDieCondition) and an empty health bar knocks out (NPCPuppet.OnPotentialDeath).
// Same targets as the health drop: humans, not bosses or MaxTac. Everything else stays as it was.

@addField(PlayerPuppet)
private let m_gorillaYeetSpare: Bool;

@addField(PlayerPuppet)
private let m_gorillaYeetSpareLight: Bool;

// Called by the CET mod about once a second.
@addMethod(PlayerPuppet)
public func GorillaYeetSetSpare(spare: Bool, lightPunches: Bool) -> Bool {
  this.m_gorillaYeetSpare = spare;
  this.m_gorillaYeetSpareLight = lightPunches;
  return true;
}

@addMethod(PlayerPuppet)
public func GorillaYeetSpares(attackData: ref<AttackData>) -> Bool {
  if !this.m_gorillaYeetSpare {
    return false;
  };
  let attackType: gamedataAttackType = attackData.GetAttackType();
  if NotEquals(attackType, gamedataAttackType.StrongMelee) && !(this.m_gorillaYeetSpareLight && Equals(attackType, gamedataAttackType.Melee)) {
    return false;
  };
  let weapon: wref<WeaponObject> = attackData.GetWeapon();
  return IsDefined(weapon) && Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Cyb_StrongArms);
}

// Gorilla Yeet 0.5.8 (Cyberslop, 2026-11-01). The spare flag is added before PreProcess: PDO reads Nonlethal in
// ProcessLocalizedDamage, which vanilla PreProcess calls, so a flag added in Process (0.5.5 to 0.5.7) came too late.
// PDO then ran its dying state on every knockout and its loop kept the body Invulnerable, which zeroed every later
// punch. Also the Unconscious effect lands a frame or two after the knockout hit, so a body in PDO's
// dying state or just knocked out counts as down through the Defeated effect and the death mark as well.
@wrapMethod(DamageSystem)
private final func PreProcess(hitEvent: ref<gameHitEvent>, cache: ref<CacheData>) -> Bool {
  let player: ref<PlayerPuppet> = hitEvent.attackData.GetInstigator() as PlayerPuppet;
  let npc: ref<NPCPuppet> = hitEvent.target as NPCPuppet;
  if IsDefined(player) && IsDefined(npc) && player.GorillaYeetSpares(hitEvent.attackData) && Equals(npc.GetNPCType(), gamedataNPCType.Human) && !npc.IsBoss() && NotEquals(npc.GetNPCRarity(), gamedataNPCRarity.MaxTac) && !npc.GorillaYeetIsDown() {
    hitEvent.attackData.AddFlag(hitFlag.Nonlethal, n"GorillaYeet");
  };
  return wrappedMethod(hitEvent, cache);
}

@wrapMethod(DamageSystem)
private final func Process(hitEvent: ref<gameHitEvent>, cache: ref<CacheData>) -> Void {
  let player: ref<PlayerPuppet> = hitEvent.attackData.GetInstigator() as PlayerPuppet;
  let npc: ref<NPCPuppet> = hitEvent.target as NPCPuppet;
  if IsDefined(player) && IsDefined(npc) && player.GorillaYeetIsSlamOn(hitEvent.attackData, npc) {
    hitEvent.attackData.AddFlag(hitFlag.Nonlethal, n"GorillaYeet");
    hitEvent.attackData.AddFlag(hitFlag.DealNoDamage, n"GorillaYeet");
    npc.GorillaYeetSlamLaunch(player);
  };
  if IsDefined(player) && IsDefined(npc) && player.GorillaYeetIsPunch(hitEvent.attackData) {
    npc.GorillaYeetMarkPunch();
  };
  wrappedMethod(hitEvent, cache);
}

// Gorilla Yeet 0.5.7 (Cyberslop, 2026-10-31). A Nonlethal punch leaves a human Unconscious, which keeps the defeat
// mechanic on, so CanDieCondition keeps refusing every further Nonlethal punch. A body that is already down gets
// a normal punch, so Non-lethal spares the first hit only and the body can still be finished.
// IsAboutToBeDefeated covers the frames between an empty health bar and its status effect.
@addMethod(NPCPuppet)
public func GorillaYeetIsDown() -> Bool {
  return ScriptedPuppet.IsUnconscious(this) || ScriptedPuppet.IsDefeated(this) || this.IsAboutToDieOrDefeated();
}

// Same head rule as No Disappearing Heads (32322), which only covers ranged hits: Gunsensical's
// GetDismembermentWoundType turns big blunt damage into a COARSE head wound, and ProcessExtendedDeathAnimData
// always asks for COARSE. A Gorilla Arms head hit gets the HOLE wound instead. The punch is stamped on the NPC
// because the hit reaction's attack data can already belong to a bleed or burn tick when the event arrives.
// Critical requests stay as they are (One Punch Man option, Head Popper). Humans only: androids keep vanilla wounds.

@addField(NPCPuppet)
private let m_gorillaPunchAt: Float;

@addMethod(PlayerPuppet)
public func GorillaYeetIsPunch(attackData: ref<AttackData>) -> Bool {
  let attackType: gamedataAttackType = attackData.GetAttackType();
  if NotEquals(attackType, gamedataAttackType.Melee) && NotEquals(attackType, gamedataAttackType.StrongMelee) {
    return false;
  };
  let weapon: wref<WeaponObject> = attackData.GetWeapon();
  return IsDefined(weapon) && Equals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Cyb_StrongArms);
}

@addMethod(NPCPuppet)
public func GorillaYeetMarkPunch() -> Void {
  this.m_gorillaPunchAt = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame()));
}

@addMethod(NPCPuppet)
public func GorillaYeetWasPunched() -> Bool {
  return this.m_gorillaPunchAt > 0.00 && EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame())) - this.m_gorillaPunchAt < 1.00 && Equals(this.GetNPCType(), gamedataNPCType.Human);
}

@wrapMethod(DismembermentComponent)
protected cb func OnDismemberment(evt: ref<DismembermentEvent>) -> Bool {
  if Equals(evt.m_bodyPart, gameDismBodyPart.HEAD) && NotEquals(evt.m_woundType, gameDismWoundType.HOLE) && !evt.m_isCritical {
    let npc: ref<NPCPuppet> = this.GetEntity() as NPCPuppet;
    if IsDefined(npc) && npc.GorillaYeetWasPunched() {
      evt.m_woundType = gameDismWoundType.HOLE;
    };
  };
  return wrappedMethod(evt);
}

// Gorilla Yeet 0.5.6 (Cyberslop, 2026-10-30). The Gorilla Arms ground slam only ragdolls humans: no damage, no
// kill, no lost limbs, on standing and downed bodies alike. Vanilla's hit reaction kills downed NPCs on Explosion
// hits (DefeatedRemoveConditions) and dismembers them (ProcessExplosionDismembement), which the Nonlethal flag
// can't stop once the defeat mechanic is off, so both are skipped here. The slam is matched by its attack records
// because it isn't reliably a PressureWave hit with a weapon. Walls can knock out but never kill.

@addField(PlayerPuppet)
private let m_gorillaYeetSlam: Bool;

@addField(PlayerPuppet)
private let m_gorillaYeetForce: Float;

@addField(PlayerPuppet)
private let m_gorillaYeetUp: Float;

@addField(NPCPuppet)
private let m_gorillaSlamAt: Float;

public class GorillaSlamCleanup extends DelayCallback {
  public let npc: ref<NPCPuppet>;
  public let tries: Int32;

  public func Call() -> Void {
    if !IsDefined(this.npc) {
      return;
    };
    // Same fix as the CET tracker: a body that goes down mid ragdoll keeps NonInteractable
    if ScriptedPuppet.IsDefeated(this.npc) || ScriptedPuppet.IsUnconscious(this.npc) || !ScriptedPuppet.IsAlive(this.npc) {
      StatusEffectHelper.RemoveStatusEffect(this.npc, t"BaseStatusEffect.NonInteractable");
    };
    if this.tries > 0 {
      let next: ref<GorillaSlamCleanup> = new GorillaSlamCleanup();
      next.npc = this.npc;
      next.tries = this.tries - 1;
      GameInstance.GetDelaySystem(this.npc.GetGame()).DelayCallback(next, 1.00, false);
    };
  }
}

// Called by the CET mod about once a second.
@addMethod(PlayerPuppet)
public func GorillaYeetSetSlam(slam: Bool, force: Float, up: Float) -> Bool {
  this.m_gorillaYeetSlam = slam;
  this.m_gorillaYeetForce = force;
  this.m_gorillaYeetUp = up;
  return true;
}

@addMethod(PlayerPuppet)
public func GorillaYeetForce() -> Float {
  return this.m_gorillaYeetForce;
}

@addMethod(PlayerPuppet)
public func GorillaYeetUp() -> Float {
  return this.m_gorillaYeetUp;
}

@addMethod(PlayerPuppet)
public func GorillaYeetIsSlamOn(attackData: ref<AttackData>, npc: ref<NPCPuppet>) -> Bool {
  if !this.m_gorillaYeetSlam || !IsDefined(attackData) || !IsDefined(attackData.GetAttackDefinition()) {
    return false;
  };
  let record: TweakDBID = attackData.GetAttackDefinition().GetRecord().GetID();
  let isPressureWave: Bool = Equals(attackData.GetAttackType(), gamedataAttackType.PressureWave);
  if !isPressureWave && NotEquals(record, t"Attacks.GroundSlamNear") && NotEquals(record, t"Attacks.GroundSlamFar") {
    return false;
  };
  // Landing shockwaves are PressureWave hits without a weapon
  if isPressureWave && !IsDefined(attackData.GetWeapon()) {
    return false;
  };
  let weapon: wref<WeaponObject> = GameObject.GetActiveWeapon(this);
  if !IsDefined(weapon) || NotEquals(WeaponObject.GetWeaponType(weapon.GetItemID()), gamedataItemType.Cyb_StrongArms) {
    return false;
  };
  return Equals(npc.GetNPCType(), gamedataNPCType.Human) && !npc.IsBoss() && NotEquals(npc.GetNPCRarity(), gamedataNPCRarity.MaxTac);
}

@addMethod(NPCPuppet)
public func GorillaYeetSlamLaunch(player: ref<PlayerPuppet>) -> Void {
  // The slam is two attacks: launch once
  let now: Float = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGame()));
  if this.m_gorillaSlamAt > 0.00 && now - this.m_gorillaSlamAt < 0.50 {
    return;
  };
  this.m_gorillaSlamAt = now;
  let from: Vector4 = player.GetWorldPosition();
  let away: Vector4 = this.GetWorldPosition() - from;
  away.Z = 0.00;
  away = Vector4.Normalize(away);
  let force: Vector4 = away * player.GorillaYeetForce();
  force.Z = player.GorillaYeetUp();
  from.Z += 1.50;
  this.PushPullMarkImpact(8.00, 11.40, 0.00, 0.00);
  this.QueueEvent(CreateForceRagdollEvent(n"GorillaYeet slam"));
  GameInstance.GetDelaySystem(this.GetGame()).DelayEvent(this, CreateRagdollApplyImpulseEvent(from, force, 900000000.00), 0.10, false);
  let cleanup: ref<GorillaSlamCleanup> = new GorillaSlamCleanup();
  cleanup.npc = this;
  cleanup.tries = 12;
  GameInstance.GetDelaySystem(this.GetGame()).DelayCallback(cleanup, 1.00, false);
}

@addMethod(HitReactionComponent)
private final func GorillaYeetIsSlamHit() -> Bool {
  if !IsDefined(this.m_attackData) || !IsDefined(this.m_ownerNPC) {
    return false;
  };
  let player: ref<PlayerPuppet> = this.m_attackData.GetInstigator() as PlayerPuppet;
  return IsDefined(player) && player.GorillaYeetIsSlamOn(this.m_attackData, this.m_ownerNPC);
}

@wrapMethod(HitReactionComponent)
protected final func ProcessDefeated(npc: ref<NPCPuppet>) -> Bool {
  if this.GorillaYeetIsSlamHit() {
    return false;
  };
  return wrappedMethod(npc);
}

@wrapMethod(HitReactionComponent)
protected final func ProcessWoundsAndDismemberment() -> Void {
  if this.GorillaYeetIsSlamHit() {
    return;
  };
  wrappedMethod();
}
