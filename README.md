============================================================
OVERVIEW

Implemented chain replication, as described in

  [vRS2004chain] Robbert van Renesse and Fred B. Schneider.  Chain
  Replication for Supporting High Throughput and Availability.  In
  Proceedings of the 6th Symposium on Operating Systems Design and
  Implementation (OSDI), pages 91-104.  USENIX Association, 2004.
  http://www.cs.cornell.edu/fbs/publications/ChainReplicOSDI.pdf

Also, designed and implemented an extension to handle an operation that
involves multiple chains, as described below.

Chain replication is also described in

  [vrG2010replication] Robbert van Renesse and Rachid Guerraoui.
  Replication Techniques for Availability. In Replication: Theory and
  Practise, Bernadette Charron-Bost, Fernando Pedone, and Andre Schiper,
  editors, volume 5959 of Lecture Notes in Computer Science, pages 19-40.
  Springer-Verlag, 2010.
  http://www.cs.cornell.edu/Courses/cs5414/2012fa/publications/vRG10.pdf

============================================================
FUNCTIONALITY OF THE REPLICATED SERVICE

the replicated service stores bank account information.  it stores the
following information for each account: (1) balance, (2) sequence of
processed updates, denoted processedTrans.

the service supports the following query and update requests.  the reply to
each request is an instance of the class Reply, shown below as a tuple for
brevity.

enum Outcome { Processed, InconsistentWithHistory, InsufficientFunds }

class Reply {
  string reqID;
  string accountNum;
  Outcome outcome;
  float balance;
}

note: making request identifiers strings (rather than numbers) allows them
to have structure, e.g., "1.1.1".  this makes it easier to generate unique
request identifiers, using a structure such as
bankName.clientNumber.sequenceNumber.

QUERIES

  getBalance(reqID, accountNum): returns <reqID, Processed, balance>.

UPDATES

  [UPDATE 2014-10-04: in each of the following 3 paragraphs, I replaced "if
  exactly the same transaction has already been processed for this account,
  simply return <reqID, Processed, balance>." with "if exactly the same
  transaction has already been processed, re-send the same reply."]

  [UPDATE 2014-10-10: in each of the following 3 paragraphs, I added
  accountNum as the second component of the reply.]

  deposit(reqID, accountNum, amount): if a transaction with this reqID has
  not been processed for this account, increase the account balance by the
  amount, append the transaction to processedTrans, and return <reqID,
  accountNum, Processed, balance>, where balance is the current balance.
  if exactly the same transaction has already been processed, re-send the
  same reply.  if a different transaction with the same reqID has been
  processed for this account, return <reqID, accountNum,
  InconsistentWithHistory, balance>.

  withdraw(reqId, accountNum, amount): if a transaction with this reqID has
  not been processed for this account, and the account balance is at least
  the amount, decrease the account balance by the amount, append the
  transaction to processedTrans, and return <reqID, accountNum, Processed,
  balance>.  if a transaction with this reqID has not been processed for
  this account, and the account balance is less than the amount, return
  <reqID, accountNum, InsufficientFunds, balance>.  if exactly the same
  transaction has already been processed, re-send the same reply.  if a
  different transaction with the same reqID has been processed for this
  account, return <reqID, accountNum, InconsistentWithHistory, balance>.
  [UPDATE 2014-10-11: added "for this account" in the preceding sentence.]

  transfer(reqID, accountNum, amount, destBank, destAccount): if a
  transaction with this reqID has not been processed for this account, and
  the account balance is at least the transfer amount, then transfer the
  requested amount of funds from the specified account in this bank to
  destAccount in destBank, and return <reqID, accountNum, Processed,
  balance>.  if a transfer with this reqID has not been processed for this
  account, and the account balance is less than the transfer amount, return
  <reqID, accountNum, InsufficientFunds, balance>.  if exactly the same
  transaction has already been processed, re-send the same reply.  if a
  different transaction with the same reqID has been processed for this
  account, return <reqID, accountNum, InconsistentWithHistory, balance>.
  [UPDATE 2014-10-11: added "for this account" in the preceding sentence
  and in the first and second sentences of this paragraph.]  [UPDATE,
  2014-09-17: added the following] It is acceptable for a server of either
  the source bank or the destination bank to send a reply to the client.
  However, the client should send the request only to a server of the
  source bank; the client should not need to send a request to a server of
  the destination bank.

  [UPDATE 2014-11-14] for simplicity, you can assume that all transfers are
  between two different banks.

============================================================
SIMPLIFICATIONS

if an account mentioned in a request does not already exist, then it is
automatically created, with initial balance 0, and then the request is
processed as described above.

assume clients never send requests with non-positive amounts.

assume the master never fails.  therefore, you do not need to implement
Paxos.

the same master is used by all banks.  the master reports every failure to
all servers of all banks.  [UPDATE, 2014-09-18: the master also reports
failures to clients.]

assume that the pattern of failures is limited so that there is always at
least one living server for each bank.

it is sufficient to store all information in RAM.  it's OK that information
stored by a process is lost when the process fails or terminates.

it is sufficient to test your system with all of the clients being threads
in a single process.  you should run testcases with up to 3 banks and up to
6 clients per bank.

============================================================
NETWORK PROTOCOLS

as stated in the paper, communication between servers should be reliable,
so use TCP as the underlying network protocol for it, and assume that TCP
is reliable.  this applies to communication between servers in the same or
different chains.  also, communication between the master and servers is
reliable, so use TCP for it.

communication between clients and servers may be unreliable, so use UDP as
the underlying network protocol for it.  for simplicity, assume that each
request or reply fits in a single UDP packet.

[UPDATE 2014-11-04] the paper does not state whether communication between
clients and the master is reliable.  for simplicity, I suggest that you
assume it is reliable, and use TCP for it.


============================================================ 
CONFIGURATION FILE

all clients, servers, and the master read information from a configuration
file whose name is specified on the command line.  for simplicity, all
three kinds of processes read the same configuration file, and each kind of
process ignores the information it does not need.  note: this implies that
configuration file contains information for all banks.

the configuration file contains enough information to specify a testcase;
thus, you can run different testcases simply by supplying different
configuration files.  information in the configuration file includes (but
is not limited to): the names of the banks, the length of the chain for
each bank, Internet addresses and port numbers of the master and servers
(for all banks), the number of clients of each bank, a description of the
requests submitted by each client (explained below), server
startup delays, and server lifetimes (explained below).

[UPDATE 2014-10-07] The DistAlgo implementation should ignore the IP
addresses and port numbers in the configuration file.

the configuration file should have a self-describing syntax.  instead of
each line containing only a value, whose meaning depends on the line number
(where it is hard for readers to remember which line number contains which
value), each line should contain a label and a value, so the reader easily
sees the meaning of each value.

[UPDATE 2014-10-12] different requests can be specified for each client.

the description of a client's requests in the configuration file can have
one of two forms: (1) a single item random(seed, numReq, probGetBalance,
probDeposit, probWithdraw, probTransfer), where seed is a seed for a
pseudo-random number generator, numReq is the number of requests that will
be issued by this client, and the remaining parameters (which should sum to
1) are the probabilities of generating the various types of requests.  (2)
a sequence of items, each representing one request using some readable and
easy-to-parse syntax, such as "(getBalance, 1.1.1, 46)".  the configuration
file should also contain separate entries controlling the following: the
duration a client waits for a reply, before either resending the request or
giving up on it; the number of times a client re-sends a request before
giving up on it; whether the client re-sends a request to the new head for
a bank, if the client, while waiting for a reply from that bank, is
notified by the master of failure of the head for the bank.

the configuration file specifies a startup delay (in milliseconds) for
each server.  a server's main thread does essentially nothing except sleep
until the server's startup delay has elapsed.  this feature facilitates
testing of the algorithm for incorporating new servers (i.e., extending the
chain).  servers that are part of the initial chain have a startup delay of
zero.

the configuration file specifies a lifetime for each server, which may be
(1) "receive" and a number n (the server terminates immediately after
receiving its n'th message), (2) "send" and a number n (the server
terminates immediately after sending its n'th message), or (3) "unbounded"
(the server never terminates itself).  furthermore, the number n in (1) and
(2) can be replaced with the string "random", in which case the server
generates a random number in a reasonable range, outputs it to a log file,
and uses that number.

[UPDATE 2014-11-02] You are welcome to implement additional forms of server
lifetime, if it helps you construct desired failure scenarios.

configuration files that satisfy some variant of the above requirements are
also acceptable, provided they provide a comparable level of control, as
needed for thorough testing of fault-tolerant distributed systems.

tip: you will have numerous configuration files.  to help keep track of them,
organize them into folders, and try to give them meaningful names.

[UPDATE 2014-10-03: added the following.]  for non-fault-tolerant service
(phase2), you do not need to consider scenarios with message loss between
clients and servers.  for subsequent phases, you do need to consider such
scenarios, because such with message loss is one of the types of failures
that chain replication is designed to tolerate.  you will need to introduce
such failures synthetically (i.e., simulate them), in a similar way as
server lifetimes (specified in the configuration file) are used to simulate
server failures.  you should introduce some lines in the configuration file
to specify when and how often message loss between clients and servers
occurs.

============================================================
LOGS

every process should generate a comprehensive log file describing its
initial settings, the content of every message it received, the content of
every message it sent, and every significant internal action it took.
every log entry should contain a real-time timestamp.  every log entry for
a sent message should contain a send sequence number n, indicating that it
is for the n'th message sent by this process.  every log entry for a received
message should contain a receive sequence number n, indicating that it is
for the n'th message received by this process.  (send and receive sequence
numbers are useful for choosing server lifetimes that correspond to
interesting failure scenarios.)  the log file should have a self-describing
syntax, in the same style as described for the configuration file.  for
example, each component of a message should be labeled to indicate its
meaning.

[UPDATE 2014-10-12] it's OK for multiple processes to write to the same log
file, provided each log entry is clearly labeled with the process that
produced it.

============================================================
FAILURE DETECTION

chain replication is designed to work correctly under the fail-stop model,
which assumes perfect failure detection (cf. [vRG2010replication, section
2.4]).  there are two completely different approaches to handling this.

the approach is to implement real failure detection, using timeouts.
for example, each server S sends a UDP packet containing S's name to the
master every 1 second.  every (say) 5 seconds, the master checks whether it
has received at least 1 message from each server that it believes is alive
during the past 5 seconds.  if not, it concludes that the uncommunicative
servers failed.  note that a few occasional dropped UDP packets should not
cause the master to conclude that a server has failed.  this approach never
misses real failures, but it can produce false alarms if enough packets are
dropped or delayed.
