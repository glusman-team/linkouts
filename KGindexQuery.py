#!/usr/bin/python3
import os
import sys
import json
import argparse
from sqlite_utils import Database

def defaultDB(name):
	here = os.path.dirname(os.path.abspath(__file__))
	cand = os.path.normpath(os.path.join(here, '..', 'KG', name))
	return cand if os.path.exists(cand) else '/net/gestalt/gestalt/KG/' + name

def edgeDict(row):
	id, kg, version, subject, predicate, object, rest = row
	data = {'id': id, 'kg': kg, 'version': version, 'subject': subject, 'predicate': predicate, 'object': object}
	try:
		# parse_constant maps NaN/Infinity/-Infinity to null, since perl's JSON parser rejects them
		rest = json.loads(rest, parse_constant=lambda c: None) if rest else {}
	except ValueError:
		rest = {}
	if not isinstance(rest, dict):
		rest = {}
	data['rest'] = rest
	return data

def likePattern(term):
	term = term.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
	return '%' + term + '%'

def queryTrials(trialsdb, ids):
	found = {}
	if not os.path.exists(trialsdb):
		return found
	db = Database(trialsdb)
	for i in range(0, len(ids), 500):
		chunk = ids[i:i+500]
		placeholders = ','.join('?' * len(chunk))
		sql = 'select nctid, info from trials where nctid in (%s)' % placeholders
		try:
			for row in db.execute(sql, chunk):
				nctid, info = row[0], row[1]
				try:
					found[nctid] = json.loads(info)
				except ValueError:
					pass
		except Exception:
			pass
	return found

def main():
	parser = argparse.ArgumentParser(description='Query the KG edge index (index.db) and the clinical trials database (clinicaltrials.db)')
	parser.add_argument('--index-db', default=None, help='index database file (default: <scriptdir>/../KG/index.db if it exists, else /net/gestalt/gestalt/KG/index.db)')
	parser.add_argument('--trials-db', default=None, help='clinical trials database file (default: <scriptdir>/../KG/clinicaltrials.db if it exists, else /net/gestalt/gestalt/KG/clinicaltrials.db)')
	parser.add_argument('--random', nargs=2, metavar=('KG', 'VERSION'), help='pick a random edge from the given kg and version')
	parser.add_argument('--narrow', default=None, help='with --random: only consider edges containing the given string (case-insensitive)')
	parser.add_argument('--trials', metavar='NCTIDS', help='comma-separated NCT ids to look up in the trials database')
	parser.add_argument('id', nargs='?', default=None, help='edge id to look up in the index database')
	args = parser.parse_args()

	indexdb = args.index_db if args.index_db is not None else defaultDB('/ssd/KG/index.db')
	trialsdb = args.trials_db if args.trials_db is not None else defaultDB('/ssd/KG/clinicaltrials.db')

	if args.trials is not None:
		ids = [x for x in args.trials.split(',') if x]
		if not ids:
			sys.exit(1)
		print(json.dumps(queryTrials(trialsdb, ids), ensure_ascii=False))
		return

	if not args.random and not args.id:
		parser.error('provide an edge id, --random, or --trials')
	if not os.path.exists(indexdb):
		sys.exit(1)

	db = Database(indexdb)
	if args.random:
		kg, version = args.random
		sql = 'select id, kg, version, subject, predicate, object, rest from edges where kg = ? and version = ?'
		params = [kg, version]
		if args.narrow:
			pattern = likePattern(args.narrow)
			conds = " or ".join(col + " like ? escape '\\'" for col in ('id', 'subject', 'predicate', 'object', 'rest'))
			sql += 'and (' + conds + ')'
			params += [pattern] * 5
		sql += ' order by random() limit 1'
		rows = list(db.execute(sql, params))
	else:
		rows = list(db.execute('select id, kg, version, subject, predicate, object, rest from edges where id = ? order by rowid limit 1', [args.id]))

	if rows:
		print(json.dumps(edgeDict(rows[0]), ensure_ascii=False))

if __name__ == '__main__':
	main()
