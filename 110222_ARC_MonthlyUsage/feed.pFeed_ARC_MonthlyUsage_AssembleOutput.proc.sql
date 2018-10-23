---- ================================================================================================
---- Author:		Mel Duarte
---- Create date: 2018-10-03
---- Description: ARC Monthly Usage data
---- ================================================================================================
---- ================================================================================================
CREATE PROCEDURE [feed].[pFeed_ARC_MonthlyUsage_AssembleOutput]
	@ClientId_Rpt INT
	,@FullFeedRun BIT
AS 
BEGIN 
	SET NOCOUNT ON
	
	DECLARE @Today DATE = GETDATE()
			,@Delimiter VARCHAR(3) =','
			,@TextQualifier VARCHAR(3) = '"'
		SET
			@FullFeedRun = ISNULL(@FullFeedRun, 0)

	
	DECLARE 
		@MonthStart DATE =  DATEADD(MONTH, DATEDIFF(MONTH, 0, @Today)-1, 0)

	IF OBJECT_ID('tempdb..#StageData') IS NOT NULL DROP TABLE #StageData
	CREATE TABLE #StageData	(
		ID INT IDENTITY (1, 1)
		,ClientID INT
		,LeavePlanID INT
		,LeaveID INT
		,EEID INT
		,HRDeptID  NVARCHAR (200)
		,OrgType NVARCHAR (200)
		,DeptName NVARCHAR (200)
		,Region NVARCHAR (200)
		,KVPUnionCode NVARCHAR (200)
		,JobTitle NVARCHAR (200)
		,EENumber NVARCHAR (200)
		,PlanStartDate DATE
		,PlanEndDate DATE
		,PlanName NVARCHAR (200)
		,LastName NVARCHAR(200)
		,FirstName NVARCHAR(200)
		,SuprName NVARCHAR (200)
		,ExternalLeaveID NVARCHAR (200)
		,LeaveStartDate DATE
		,LeaveEndDate DATE
		,HoursUsed INT
		,HoursAvailable INT
		,HoursRemaining INT
		,WorkType NVARCHAR(50)
		,LeaveType NVARCHAR (200)
		,LeaveReason NVARCHAR (200)
		,LeaveStatus NVARCHAR (50)
		,FrequencyDuration NVARCHAR (200)
		,PlanSegmentDates NVARCHAR (200)	--Only report segment dates for CONT/RED
	)


	--Stage main data/segment data
	INSERT INTO #StageData (
		ClientID
		,LeavePlanID
		,LeaveId
		,EEID
		,KVPUnionCode
		,JobTitle
		,EENumber
		,PlanStartDate
		,PlanEndDate
		,PlanName
		,LastName
		,FirstName
		,SuprName
		,ExternalLeaveID
		,LeaveStartDate
		,LeaveEndDate
		,HoursAvailable
		,WorkType
		,LeaveType
		,LeaveReason
		,LeaveStatus
		,FrequencyDuration
		,PlanSegmentDates
	)
	SELECT
		e.ClientID
		,lp.LeavePlanID
		,l.LeaveID
		,e.EmployeeID
		,ekvp.[Value]
		,j.JobTitle
		,e.EmployeeNumber
		,lps.PlanStartDate
		,lps.PlanEndDate
		,lp.LeavePlan
		,e.LastName
		,e.FirstName
		,SuprName = (e2.FirstName + ' ' + e2.LastName)
		,l.ExternalLeaveID
		,l.DateExtentMin
		,l.DateExtentMax
		,(lp.MaxPlanMinutes/60)
		,lp.WorkType
		,lp.LeaveType
		,l.LeaveReason
		,l.LeaveStatus
		,FrequencyAndDuration = dbo.fRpt_GetIntermittentCertFreqAndDuration(l.LeaveID, CAST(lps.PlanStartDate AS DATETIME), CAST(lps.PlanEndDate AS DATETIME), @ClientID_rpt)
		,PlanSegmentDates = CASE WHEN lp.WorkType IN ('CONT','RED')
									THEN CONVERT(CHAR(10), lps.PlanStartDate, 101) + ' to ' + CONVERT(CHAR(10), lps.PlanEndDate, 101)
								ELSE NULL 
							END	
	FROM
		Leave l
		INNER JOIN dbo.Employee e 
			ON l.EmployeeID = e.EmployeeID
		INNER JOIN dbo.LeavePlan lp 
			ON l.LeaveId = lp.LeaveId
			AND lp.WorkType IN ('CONT','INT','RED')
		INNER JOIN dbo.LeavePlanSegment lps	
			ON lp.LeavePlanID = lps.LeavePlanID
		INNER JOIN job j 
			ON e.EmployeeID = j.EmployeeID
			AND j.IneffectiveDate IS NULL
			AND l.DateExtentMin BETWEEN j.FromDate AND ISNULL(j.ThruDate,l.DateExtentMin)
		INNER JOIN dbo.EmployeeContact ec
			ON e.EmployeeId = ec.EmployeeId
		INNER JOIN dbo.Employee e2
			ON ec.ContactID = e2.EmployeeID
			AND ec.ContactType = 'Supervisor'
		LEFT JOIN dbo.EmployeeKeyValue ekvp		--Required KVP
			ON e.EmployeeID = ekvp.EmployeeID
			AND ekvp.[Key] = 'Union Codes' 
	WHERE	
		l.ClientID = @ClientId_rpt
		AND l.LeaveStatus IN ('Open' , 'Closed')
		AND lps.StatusCode IN ('APPROVE','DENY','DEN-PENDST','PEND','PEND-DET')
		AND ((
			CAST(l.ChangedDate AS DATE) >= @MonthStart
			OR CAST(lp.ChangedDate AS DATE) >= @MonthStart
			OR CAST(lps.ChangedDate AS DATE) >= @MonthStart	
			)	
				OR (
					@FullFeedRun = 1
				))
	ORDER BY
		LastName
		,ExternalLeaveID
		
	--Update Org Values
	;WITH cteOrgs AS
	(
		SELECT
			o.ClientID
		   ,eo.EmployeeId
		   ,o.OrganizationName
		   ,o.OrganizationType
		   ,ROW_NUMBER() OVER (PARTITION BY eo.EmployeeId, o.OrganizationType ORDER BY eo.EmployeeId) rnum
		FROM EmployeeOrganization eo
			INNER JOIN Organization o
				ON o.OrganizationID = eo.OrganizationId
				AND eo.IneffectiveDate IS NULL
		WHERE 
			o.ClientID = @clientId_Rpt
	),
	cteOrgPivot AS
	(
		SELECT
			PVT.ClientID
			,EmployeeId
		   ,PVT.[Cost Center]
		   ,PVT.Locality
		   ,PVT.[Work Site]
		   ,PVT.Client
		FROM 
		(
			SELECT
				OrganizationName
			   ,OrganizationType
			   ,ClientID
			   ,EmployeeId
			FROM 
				cteOrgs
			WHERE 
				rnum = 1) P
		PIVOT
		(
			MAX(P.OrganizationName)
			FOR P.OrganizationType IN( [Cost Center], Locality, [Work Site], Client)
		) PVT
		WHERE 
			PVT.ClientID = @clientId_Rpt
	)
	UPDATE sd
	SET
		HRDeptID = o.[cost center]
		,OrgType = o.Locality
		,DeptName = o.[Work Site]
		,Region = o.client
	FROM
		#StageData sd
		INNER JOIN cteOrgPivot o
			ON o.EmployeeId = sd.EEID

	--**********************************************
	--		Calc Leave Plan Usage
	--**********************************************
	;WITH LeavePlanUsage AS
	(
		SELECT 
			 sd.LeavePlanID
			,lp.LeavePlanCode
			,TimeUsed = CASE WHEN sd.LeaveStatus = 'Denied' THEN 0.0 -- No usage for Denied Plan
							ELSE (SUM(pu.TimeLost/60)) END --Do not limit future plan usage data
		FROM
			#StageData sd
			INNER JOIN dbo.LeavePlan lp 
				ON sd.LeavePlanID = lp.LeavePlanID
			INNER JOIN dbo.PlanUsage pu 
				ON sd.LeavePlanID = pu.LeavePlanID
				AND pu.PlanUsageDate BETWEEN sd.PlanStartDate AND sd.PlanEndDate
				AND pu.TimeLost > 0
		GROUP BY
			 sd.LeavePlanID
			,lp.LeavePlanCode
			,sd.LeaveStatus
	)
	--Update Hours Used
	UPDATE sd
	SET 
		HoursUsed = ISNULL(lpu.timeused, 0)
	FROM
		#StageData sd
		INNER JOIN LeavePlanUsage lpu
			ON sd.LeavePlanID = lpu.LeavePlanID

	--Update Hours remaining
	UPDATE sd
	SET
		HoursRemaining = ISNULL((pu.totaltimeremaining / 60), 0)
	FROM
		#StageData sd
		LEFT JOIN dbo.PlanUsage pu 
			ON sd.leaveplanid = pu.leaveplanid
		WHERE
			pu.PlanUsageDate = CASE 
									WHEN sd.PlanEndDate < @Today THEN sd.PlanEndDate
									ELSE @today
								END 

	IF OBJECT_ID('tempdb..#Output') IS NOT NULL DROP TABLE #Output
	CREATE TABLE #Output(ID INT IDENTITY (1, 1), OutputData NVARCHAR(MAX))

	--Output section
	IF 1=2
	BEGIN
		SELECT
			OutputData = CAST(NULL AS NVARCHAR(MAX))
		RETURN;
	END

	--Header values
	INSERT INTO #Output (OutputData)				
		VALUES (	
				@TextQualifier + N'HR Department ID'				+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Work Location Code'				+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Department Name'					+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Region'							+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Union Code'						+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Job Title'						+ @TextQualifier + @Delimiter + 	
				@TextQualifier + N'HRID'							+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Benefit Type'					+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Last Name'						+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'First Name'						+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Supervisor Name'					+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Claim Number'					+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Claim Start Date'				+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Claim End Date'					+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Hours Used'						+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Initial Hours Available'			+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Hours Remaining'					+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Work Type'						+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Leave Type'						+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Reason for Absence'				+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Expected Usage In'				+ @TextQualifier + @Delimiter + 
				@TextQualifier + N'Expected Usage Cont and Red'		+ @TextQualifier
			)

	--Assemble output data
	INSERT INTO #Output (OutputData)
		SELECT
			'=' +		--Equal needed for first field to keep leading zeroes and avoid scientific notation in Excel
			@TextQualifier + ISNULL(HRDeptID,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(OrgType,'')								+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(DeptName,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(Region,'')								+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(KVPUnionCode,'')						+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(JobTitle,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(EENumber,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(PlanName,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(LastName,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(FirstName,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(SuprName,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(ExternalLeaveID,'')						+ @TextQualifier + @Delimiter + 
			@TextQualifier + CONVERT(CHAR(10), LeaveStartDate, 101)			+ @TextQualifier + @Delimiter + 
			@TextQualifier + CONVERT(CHAR(10), LeaveEndDate, 101)			+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(CAST(HoursUsed AS NVARCHAR), 0)			+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(CAST(HoursAvailable AS NVARCHAR),'')	+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(CAST(HoursRemaining AS NVARCHAR),'')	+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(WorkType,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(LeaveType,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(LeaveReason,'')							+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(FrequencyDuration,'')					+ @TextQualifier + @Delimiter + 
			@TextQualifier + ISNULL(PlanSegmentDates,'')					+ @TextQualifier
	FROM 
		#StageData
	WHERE 
		ClientID = @ClientId_Rpt
	ORDER BY 
		OrgType
		,LastName
		,ExternalLeaveID
	
	--Output to SSIS
	SELECT
		OutputData
	FROM 
		#Output
	ORDER BY 
		ID

END
GO