'reach 0.1';

const message = Bytes(22);
const fromMap = (m) => fromMaybe(m, () => 0, (x) => x);

export const main = Reach.App(() => {
	setOptions({ untrustworthyMaps: true });

	const FundRaiser = Participant("FundRaiser", {
		...hasRandom,
		metaDataHash: Bytes(256),
		duration: UInt,
		targetAmount: UInt,
		getContributionNotification: Fun([Tuple(Address, UInt)], Null),
		refundContributors: Fun([], Null),
		ownerCashOut: Fun([], Null),
	});

	const Contributors = API("Contributors", {
		getMetaDataHash: Fun([], Bytes(256)),
		contribute: Fun([UInt], Null),
		tryReclaim: Fun([], Bool),
	});

	const eventLogger = Events({
		log: [message],
	});

	init();

	FundRaiser.only(() => {
		const metaDataHash = declassify(interact.metaDataHash);
		const duration = declassify(interact.duration);
		const targetAmount = declassify(interact.targetAmount);
	});

	FundRaiser.publish(metaDataHash, duration, targetAmount);

	commit();

	FundRaiser.publish();

	eventLogger.log(message.pad("intialise-contribution"));

	const contributorsList = new Map(Address, UInt);
	const conSet = new Set();

	commit();

	FundRaiser.publish();

	const [timeRemaining, keepGoing] = makeDeadline(duration);

	const INITIAL_COUNT = 1;

	const [count, currentBal, lastAddress] = parallelReduce([
		INITIAL_COUNT,
		balance(),
		FundRaiser,
	])
		.invariant(balance() == currentBal)
		.while(keepGoing())
		.api_(Contributors.getMetaDataHash, () => {
			return [
				(notify) => {
					notify(metaDataHash);
					return [count, balance(), this];
				},
			];
		})
		.api_(Contributors.contribute, (amt) => {
			check(amt > 0, "Contribution too small");
			const payment = amt;
			return [
				payment,
				(notify) => {
					notify(null);
					if (conSet.member(this)) {
						contributorsList[this] = fromMap(contributorsList[this]) + amt;
					}
					else {
						conSet.insert(this);
						contributorsList[this] = amt;
					}
					FundRaiser.interact.getContributionNotification([this, amt]);
					return [count + 1, currentBal + payment, this];
				},
			];
		})
		.timeout(timeRemaining(), () => {
			FundRaiser.publish();
			eventLogger.log(message.pad("timeout"));
			return [count, currentBal, lastAddress];
		});
	if (balance() >= targetAmount) {
		eventLogger.log(message.pad("target-reached"));
		FundRaiser.interact.ownerCashOut();
		transfer(balance()).to(FundRaiser);
	}
	else {
		eventLogger.log(message.pad("target-not-reached"));
		FundRaiser.interact.refundContributors();
		const currentBalance = parallelReduce(balance())
			.invariant(balance() == currentBalance)
			.while(currentBalance > 0)
			.api(Contributors.tryReclaim, (notify) => {
				if (conSet.member(this)) {
					if (balance() >= fromMap(contributorsList[this])) {
						transfer(fromMap(contributorsList[this])).to(this);
						conSet.remove(this);
						notify(true);
					} else {
						notify(false);
					}
				}
				else {
					notify(false);
				}
				return balance();
			});
	}
	transfer(balance()).to(FundRaiser);
	eventLogger.log(message.pad("close-contribution"));
	commit();
	exit();
});
