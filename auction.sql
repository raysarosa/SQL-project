-- Use AdventureWorks database
USE AdventureWorks
GO

-- Drop procedures
DROP PROCEDURE IF EXISTS Auctions.uspAddProductToAuction, 
Auctions.uspTryBidProduct, 
Auctions.uspRemoveProductFromAuction, 
Auctions.uspListBidsOffersHistory, 
Auctions.uspUpdateProductAuctionStatus;
GO

-- Drop tables
DROP TABLE IF EXISTS Auctions.Products, 
Auctions.BidsOffers;
GO

-- Drop the schema
DROP SCHEMA IF EXISTS Auctions;
GO

-- Create the schema Auctions
CREATE SCHEMA Auctions;
GO

-- Create the table Auctions.Products
CREATE TABLE Auctions.Products (
    ProductID INT PRIMARY KEY,
    ExpireDate DATETIME,
    InitialBidPrice MONEY,
    AuctionStatus VARCHAR(20) DEFAULT 'Active', -- Add AuctionStatus column with default value 'Active'
    CONSTRAINT FK_ProductID FOREIGN KEY (ProductID) REFERENCES Production.Product (ProductID)
);
GO

-- Create the stored procedure Auctions.uspAddProductToAuction
CREATE PROCEDURE Auctions.uspAddProductToAuction
    @ProductID INT,
    @ExpireDate DATETIME = NULL,
    @InitialBidPrice MONEY = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ListPrice MONEY, @MakeFlag BIT, @SellEndDate DATETIME, @DiscontinuedDate DATETIME;
    DECLARE @CurrentDateTime DATETIME = '2014-11-14 ' + CONVERT(VARCHAR(8), GETDATE(), 108); -- Set current date and time

    BEGIN TRY
        -- Begin the transaction
        BEGIN TRANSACTION;

        -- Validation of parameters
        IF @ProductID IS NULL
        BEGIN
            THROW 50000, 'ProductID cannot be NULL.', 1;
        END;

		-- Check if Product is commercialized (SellEndDate and DiscontinuedDate are NULL and ListPrice is NOT NULL and <> 0)
		SELECT @ListPrice = ListPrice, @MakeFlag = MakeFlag, @SellEndDate = SellEndDate, @DiscontinuedDate = DiscontinuedDate 
		FROM Production.Product WHERE ProductID = @ProductID;

		IF @ListPrice IS NULL OR @ListPrice = 0 OR @SellEndDate IS NOT NULL OR @DiscontinuedDate IS NOT NULL
		BEGIN
			THROW 50001, 'Product is not currently commercialized.', 1;
		END;

		-- If @ExpireDate is not provided, set it to "2014-11-14" (when Auctions starts) plus 1 week ('2014-11-21')
        IF @ExpireDate IS NULL
        BEGIN
            SET @ExpireDate = DATEADD(WEEK, 1, @CurrentDateTime); -- Default expire date to one week from '2014-11-14'
        END
        ELSE 
        BEGIN
            -- If @ExpireDate is provided, ensure it's within the valid range
            IF @ExpireDate < '2014-11-14' OR @ExpireDate > '2014-11-30'
            BEGIN
                THROW 50002, 'ExpireDate must be between November 14 and November 30, 2014.', 1;
            END;
        END;

        -- If @InitialBidPrice is not provided, calculate based on MakeFlag
        IF @InitialBidPrice IS NULL
        BEGIN
            IF @MakeFlag = 1
            BEGIN
                SET @InitialBidPrice = 0.50 * @ListPrice; -- 50% of ListPrice for manufactured products
            END
            ELSE
            BEGIN
                SET @InitialBidPrice = 0.75 * @ListPrice; -- 75% of ListPrice for non-manufactured products
            END;
        END
        ELSE 
        BEGIN
            -- If @InitialBidPrice is provided, ensure it meets the conditions
            IF (@MakeFlag = 1 AND @InitialBidPrice < 0.50 * @ListPrice) OR
               (@MakeFlag = 0 AND @InitialBidPrice < 0.75 * @ListPrice) OR
               (@InitialBidPrice >= @ListPrice)
            BEGIN
                THROW 50003, 'InitialBidPrice must meet the conditions: 50% of ListPrice for manufactured products, 75% of ListPrice for non-manufactured products, and less than ListPrice.', 1;
            END;
        END;

        -- Insert the product into the Auctions.Products table
        INSERT INTO Auctions.Products (ProductID, ExpireDate, InitialBidPrice)
        VALUES (@ProductID, @ExpireDate, @InitialBidPrice);

        -- Commit the transaction if everything is successful
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- Rollback the transaction in case of any error
        ROLLBACK TRANSACTION;

        -- Throw the error to the caller
        THROW;
    END CATCH;
END;
GO



-- Create the table Auctions.BidsOffers
CREATE TABLE Auctions.BidsOffers (
    ProductID INT,
    CustomerID INT,
    BidAmount MONEY,
    BidTime DATETIME DEFAULT GETDATE(),
    CONSTRAINT FK_ProductID_BidsOffers FOREIGN KEY (ProductID) REFERENCES Production.Product (ProductID),
    CONSTRAINT FK_CustomerID_BidsOffers FOREIGN KEY (CustomerID) REFERENCES Sales.Customer (CustomerID) -- Assuming CustomerID is a foreign key to Sales.Customer
);
GO


-- Create the stored procedure Auctions.uspTryBidProduct
CREATE PROCEDURE Auctions.uspTryBidProduct
    @ProductID INT,
    @CustomerID INT,
    @BidAmount MONEY = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LastBidAmount MONEY, @MaxBid MONEY, @CurrentDateTime DATETIME, @InitialBidPrice MONEY, @ExpireDate DATETIME, @AuctionStatus VARCHAR(20);

    BEGIN TRY
        -- Begin the transaction
        BEGIN TRANSACTION;

        -- Validation of parameters
        IF @ProductID IS NULL OR @CustomerID IS NULL
        BEGIN
            THROW 50000, 'ProductID and CustomerID cannot be NULL.', 1;
        END;

        -- Check if the product exists in the Auctions.Products table
        IF NOT EXISTS (SELECT 1 FROM Auctions.Products WHERE ProductID = @ProductID)
        BEGIN
            THROW 50001, 'Product does not exist in the auction.', 1;
        END;

        -- Check if the product has "Cancelled" AuctionStatus
        SELECT @AuctionStatus = AuctionStatus FROM Auctions.Products WHERE ProductID = @ProductID;
        IF @AuctionStatus = 'Cancelled'
        BEGIN
            THROW 50008, 'Bidding is not allowed for products with "Cancelled" AuctionStatus.', 1;
        END;

        -- Check if the customer exists in the Sales.Customer table
        IF NOT EXISTS (SELECT 1 FROM Sales.Customer WHERE CustomerID = @CustomerID)
        BEGIN
            THROW 50002, 'Customer does not exist.', 1;
        END;

        -- Set the fixed current date and time
        SET @CurrentDateTime = '2014-11-16 ' + CONVERT(VARCHAR(8), GETDATE(), 108);

        -- Get the ListPrice for the ProductID
        SELECT @MaxBid = ListPrice FROM Production.Product WHERE ProductID = @ProductID;

        -- Get the InitialBidPrice for the ProductID
        SELECT @InitialBidPrice = InitialBidPrice FROM Auctions.Products WHERE ProductID = @ProductID;

        -- Get the ExpireDate for the ProductID
        SELECT @ExpireDate = ExpireDate FROM Auctions.Products WHERE ProductID = @ProductID;

        -- Get the last bid amount for the ProductID
        SELECT @LastBidAmount = ISNULL(MAX(BidAmount), @InitialBidPrice) FROM Auctions.BidsOffers WHERE ProductID = @ProductID;

        -- Check if the provided bid amount is valid
        IF @BidAmount IS NULL 
        BEGIN
            -- If BidAmount is not provided, set it to the last bid amount plus 0.05 or the initial bid price plus 0.05
            SET @BidAmount = @LastBidAmount + 0.05;
        END
        ELSE IF @BidAmount < @InitialBidPrice + 0.05 OR @BidAmount < @LastBidAmount + 0.05
        BEGIN
            THROW 50007, 'The minimum bid should be at least 5 cents higher than the last bid amount or initial bid price.', 1;
        END;

        -- Check if the bid is within the allowed bidding period
        IF @CurrentDateTime NOT BETWEEN '2014-11-16' AND '2014-11-30'
        BEGIN
            THROW 50004, 'Bidding is only allowed between November 16 and November 30, 2014.', 1;
        END;

        -- Check if BidTime is before or at the time of ExpireDate
        IF @CurrentDateTime > @ExpireDate
        BEGIN
            THROW 50005, 'Bidding is only allowed before or at the time of auction expiry.', 1;
        END;

        -- Check if bid amount reaches the maximum bid limit
        IF @BidAmount >= @MaxBid
        BEGIN
            THROW 50006, 'Bid amount has reached the maximum bid limit.', 1;
        END;

        -- Insert the bid into the Auctions.BidsOffers table
        INSERT INTO Auctions.BidsOffers (ProductID, CustomerID, BidAmount, BidTime)
        VALUES (@ProductID, @CustomerID, @BidAmount, @CurrentDateTime);

        -- Commit the transaction if everything is successful
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- Rollback the transaction in case of any error
        ROLLBACK TRANSACTION;

        -- Throw the error to the caller
        THROW;
    END CATCH;
END;
GO




-- CREATE THE PROCEDURE uspRemoveProductFromAuction
CREATE PROCEDURE Auctions.uspRemoveProductFromAuction
    @ProductID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AuctionStatus VARCHAR(20);

    BEGIN TRY
        -- Begin the transaction
        BEGIN TRANSACTION;

        -- Validation of parameters
        IF @ProductID IS NULL
        BEGIN
            THROW 50009, 'ProductID cannot be NULL.', 1;
        END;

        -- Check if the product exists in the Auctions.Products table
        IF NOT EXISTS (SELECT 1 FROM Auctions.Products WHERE ProductID = @ProductID)
        BEGIN
            THROW 50010, 'Product does not exist in the auction.', 1;
        END;

        -- Check if the auction status of the product is already 'Cancelled'
        SELECT @AuctionStatus = AuctionStatus FROM Auctions.Products WHERE ProductID = @ProductID;
        IF @AuctionStatus = 'Cancelled'
        BEGIN
            THROW 50011, 'The product was already cancelled from the auction.', 1;
        END;

        -- Update the AuctionStatus of the product to 'Cancelled'
        UPDATE Auctions.Products SET AuctionStatus = 'Cancelled' WHERE ProductID = @ProductID;

        -- Commit the transaction if everything is successful
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- Rollback the transaction in case of any error
        ROLLBACK TRANSACTION;

        -- Throw the error to the caller
        THROW;
    END CATCH;
END;
GO

-- CREATE THE PROCEDURE uspListBidsOffersHistory
CREATE PROCEDURE Auctions.uspListBidsOffersHistory
    @CustomerID INT,
    @StartTime DATETIME,
    @EndTime DATETIME,
    @Active BIT = 1 -- Default to true for active bids
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- Begin the transaction
        BEGIN TRANSACTION;

        IF @Active = 1
        BEGIN
            -- Active auctions
            SELECT 
                BO.ProductID,
                BO.CustomerID,
                BO.BidAmount,
                BO.BidTime,
                P.AuctionStatus
            FROM 
                Auctions.BidsOffers AS BO
            INNER JOIN
                Auctions.Products AS P ON BO.ProductID = P.ProductID
            WHERE 
                BO.CustomerID = @CustomerID
                AND P.AuctionStatus = 'Active'
                AND BO.BidTime BETWEEN @StartTime AND @EndTime;
        END
        ELSE
        BEGIN
            -- All bids regardless of auction status
            SELECT 
                BO.ProductID,
                BO.CustomerID,
                BO.BidAmount,
                BO.BidTime,
                P.AuctionStatus
            FROM 
                Auctions.BidsOffers AS BO
            INNER JOIN
                Auctions.Products AS P ON BO.ProductID = P.ProductID
            WHERE 
                BO.CustomerID = @CustomerID
                AND BO.BidTime BETWEEN @StartTime AND @EndTime;
        END;

        -- Commit the transaction if everything is successful
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- Rollback the transaction in case of any error
        ROLLBACK TRANSACTION;

        -- Throw an error if an exception occurs
        DECLARE @ErrorMessage NVARCHAR(MAX);
        SET @ErrorMessage = ERROR_MESSAGE();
        THROW 51000, @ErrorMessage, 1;
    END CATCH;
END;
GO

-- CREATE THE PROCEDURE uspUpdateProductAuctionStatus
CREATE PROCEDURE Auctions.uspUpdateProductAuctionStatus
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentDateTime DATETIME;

    BEGIN TRY
        -- Begin the transaction
        BEGIN TRANSACTION;

        -- Set the fixed current date and time
        SET @CurrentDateTime = '2014-11-16 ' + CONVERT(VARCHAR(8), GETDATE(), 108);

        -- Update the AuctionStatus of products where the auction has expired but not reached maximum bid
        UPDATE Auctions.Products
        SET AuctionStatus = 'Sold'
        FROM Auctions.Products AS P
        INNER JOIN (
            -- Subquery to check if the product has reached its expire date but not its maximum bid
            SELECT P.ProductID
            FROM Auctions.Products AS P
            LEFT JOIN (
                SELECT ProductID, MAX(BidAmount) AS MaxBid
                FROM Auctions.BidsOffers
                GROUP BY ProductID
            ) AS Bids ON P.ProductID = Bids.ProductID
            INNER JOIN Production.Product AS Prod ON P.ProductID = Prod.ProductID
            WHERE P.AuctionStatus = 'Active'
            AND P.ExpireDate <= @CurrentDateTime
            AND (Bids.MaxBid IS NULL OR Bids.MaxBid < Prod.ListPrice)
            AND P.AuctionStatus <> 'Cancelled'  -- Exclude products with AuctionStatus 'Cancelled'
        ) AS ExpiredProducts ON P.ProductID = ExpiredProducts.ProductID;

        -- Commit the transaction if everything is successful
        COMMIT TRANSACTION;

        -- Return only one row for each different ProductID with the details for the LastBidAmount
        SELECT TOP 1 WITH TIES
            BO.ProductID,
            P.ExpireDate,
            P.InitialBidPrice,
            BO.CustomerID,
            BO.BidAmount,
            BO.BidTime,
            P.AuctionStatus
        FROM 
            Auctions.BidsOffers AS BO
        INNER JOIN
            Auctions.Products AS P ON BO.ProductID = P.ProductID
        WHERE 
            P.AuctionStatus <> 'Cancelled'  -- Exclude products with AuctionStatus 'Cancelled'
        ORDER BY 
            ROW_NUMBER() OVER (PARTITION BY BO.ProductID ORDER BY BO.BidTime DESC);

    END TRY
    BEGIN CATCH
        -- Rollback the transaction in case of any error
        ROLLBACK TRANSACTION;

        -- Throw an error to the caller
        THROW;
    END CATCH;
END;
GO